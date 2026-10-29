; gsasm.asm - GRiDSound 1.0.0: the hardware part of the GRiDSound library.
; By Conventional Memories (C.M._). MIT license, see LICENSE.
; (Version 1.0.0: keep it the same as in gridsound.inc and gsfile.pas.)
;
; Background sound for GRiD Compass programs: two sampled voices mixed
; together, DTMF tones, volume, stop, "is it playing", clean shutdown.
; The Pascal declarations are in gridsound.inc, the file loader is in
; gsfile.pas. Copy all three into a program's project folder.
;
;   DFE4:0002  sound DAC (8 bits): the mix goes here, one byte a sample
;   DFE4:0004  volume DAC of the DTMF chip
;   DFEC:0002  8255 port B: DTMF digit (bits 0-6, low = picked), bit 7 on
;   DFEC:0006  8255 control: 01H sets PC0 (voice mode), 00H clears it
;   DFF0:0000  8274 serial chip, channel A data (the RS-232 port)
;   DFF0:0004  channel A control
;   ports 0/2  the 80130's interrupt controller (IR0 = serial chip)
;   ports 0CH/0EH  timer 2, the serial chip's clock
;
; How it plays (found with SoundTest 0.7, used in MusicPlay 0.3.0): the
; serial chip sends dummy bytes with nothing plugged in and interrupts
; on IR0 each time it can take the next one. Each interrupt mixes one
; sample of both voices and writes it to the DAC. Timer 2 sets the rate:
; about 517500 / count samples a second (measured on a real Compass:
; count 121 = 4.28 kHz, 61 = 8.48 kHz, 44 = 11.73 kHz).
;
; The interrupt only runs while something plays. When both voices have
; ended (and no timed DTMF tone is counting), the routine switches the
; serial chip's interrupt off and gives IR0 back (its old vector and
; mask), so a silent program costs no CPU time. The next GsPlay or
; timed GsTone starts it again.
;
; Samples are 8-bit unsigned (128 = silence) at the open rate: each
; voice plays one byte per interrupt (gsfile.pas converts files to the
; open rate when it loads them). Each voice has its own volume table
; (byte -> signed level), the two are added, clipped, and sent out.
;
; Called from Pascal-86 (compact model): near calls, parameters pushed
; left to right, the procedure removes them. VAR parameters are far
; pointers (offset at the lower address).

		NAME	GSASM

CGROUP		GROUP	CODE

CODE		SEGMENT	PUBLIC 'CODE'
		ASSUME	CS:CGROUP, DS:NOTHING, ES:NOTHING

		PUBLIC	GSOPEN, GSCLOSE, GSRATE, GSRUNNING, GSVERSION
		PUBLIC	GSPLAY, GSSTOP, GSSTOPSOUND, GSPLAYING, GSVOLUME
		PUBLIC	GSTONE, GSTONEOFF, GSTONEBUSY, GSTONEVOL
		PUBLIC	GSSETNAME, GSCONVINIT, GSCONV

dacSeg		EQU	0DFE4H
dacSound	EQU	2
dacVolume	EQU	4
mdmSeg		EQU	0DFECH		; the 8255
mdmPortB	EQU	2
mdmCtrl		EQU	6
serSeg		EQU	0DFF0H
serDataA	EQU	0
serCtrlA	EQU	4
gsVer		EQU	10000		; 1.0.0 as major*10000 + feature*100 + fix

; ---------- variables (in the code segment; first, so the assembler
; knows them before they are used) ----------
isOpen		DB	0			; GsOpen was called
running		DB	0			; the interrupt is on
v0On		DB	0			; voice 0
v0Loop		DB	0
v0Pos		DW	0			; v0Pos, v0Seg: one far pointer
v0Seg		DW	0
v0End		DW	0
v0Start		DW	0
v0Lvl		DW	2			; volume, 2 = the fast one
v0Tab		DB	0			; 1: volume table, 0: fast
v1On		DB	0			; voice 1
v1Loop		DB	0
v1Pos		DW	0
v1Seg		DW	0
v1End		DW	0
v1Start		DW	0
v1Lvl		DW	2
v1Tab		DB	0
toneLeft	DW	0			; samples until a timed tone ends
toneVol		DB	255			; the volume DAC for tones
rateHz		DW	0			; samples a second (about)
oldOff		DW	0			; the IR0 vector before
oldSeg		DW	0
oldMask		DB	0			; the interrupt mask before
cvI		DW	0			; GsConv: where it is in the chunk,
cvF		DB	0			; the fraction,
cvOut		DW	0			; bytes written so far
cvBase		DW	0
cvEnd		DW	0
; DTMF digits 0-9, * (10), # (11): port B rows (bits 3-6) and columns
; (bits 0-2), low = picked; bit 7 is added when the tone plays
digTab		DB	3DH, 76H, 75H, 73H, 6EH, 6DH, 6BH, 5EH, 5DH, 5BH, 3EH, 3BH
vol0		DB	256 DUP (0)		; voice 0: byte -> signed level
vol1		DB	256 DUP (0)		; voice 1
; the interrupt routine for each state, by v0 (2) + v1 (4) + tone (8)
; + voice 0 with a volume table (16) + voice 1 with one (32)
isrTab		DW	0, OFFSET CGROUP:IsrAf, OFFSET CGROUP:IsrBf, OFFSET CGROUP:IsrAfBf
		DW	OFFSET CGROUP:IsrT, OFFSET CGROUP:IsrAfT, OFFSET CGROUP:IsrBfT, OFFSET CGROUP:IsrAfBfT
		DW	0, OFFSET CGROUP:IsrAt, 0, OFFSET CGROUP:IsrAtBf
		DW	0, OFFSET CGROUP:IsrAtT, 0, OFFSET CGROUP:IsrAtBfT
		DW	0, 0, OFFSET CGROUP:IsrBt, OFFSET CGROUP:IsrAfBt
		DW	0, 0, OFFSET CGROUP:IsrBtT, OFFSET CGROUP:IsrAfBtT
		DW	0, 0, 0, OFFSET CGROUP:IsrAtBt
		DW	0, 0, 0, OFFSET CGROUP:IsrAtBtT

; ---------- helpers ----------

; FillVol: AX = level (8 = as the sound is), BX = OFFSET of a volume
; table. Each entry = (byte - 128) * level / 8, clipped to -128..127.
FillVol		PROC	NEAR
		PUSH	SI
		PUSH	CX
		PUSH	DX
		MOV	CX, AX
		XOR	SI, SI
FvNext:		MOV	AX, SI
		SUB	AX, 128
		IMUL	CX
		SAR	AX, 1
		SAR	AX, 1
		SAR	AX, 1
		CMP	AX, -128
		JGE	FvLow
		MOV	AX, -128
FvLow:		CMP	AX, 127
		JLE	FvHigh
		MOV	AX, 127
FvHigh:		MOV	CS:[BX+SI], AL
		INC	SI
		CMP	SI, 256
		JB	FvNext
		POP	DX
		POP	CX
		POP	SI
		RET
FillVol		ENDP

; Ramp: moves the DAC one step at a time from AL to AH, so the start and
; end don't click. Uses BX, CX, DS.
Ramp		PROC	NEAR
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
RpNext:		MOV	[BX], AL
		MOV	CX, 40
RpWait:		LOOP	RpWait
		CMP	AL, AH
		JE	RpDone
		JB	RpUp
		DEC	AL
		JMP	RpNext
RpUp:		INC	AL
		JMP	RpNext
RpDone:		RET
Ramp		ENDP

; Safe: how the PROM leaves things: sound DAC 0, volume DAC 0, port B
; 7FH (no tone), PC0 off. Uses BX, DS.
Safe		PROC	NEAR
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	BYTE PTR [BX], 0
		MOV	BX, dacVolume
		MOV	BYTE PTR [BX], 0
		MOV	BX, mdmSeg
		MOV	DS, BX
		MOV	BX, mdmPortB
		MOV	BYTE PTR [BX], 7FH
		MOV	BX, mdmCtrl
		MOV	BYTE PTR [BX], 0
		RET
Safe		ENDP

; StartIrq (interrupts off): call after a voice or timed tone starts.
; If the interrupt is off: takes IR0 (unmasked, the vector for what now
; plays), lets the serial chip interrupt when it can send, and sends the
; first dummy byte. If it is on: just the right vector (Reselect).
; Uses AX, BX, DS.
StartIrq	PROC	NEAR
		CMP	running, 0
		JE	SiStart
		CALL	Reselect
		RET
SiStart:	MOV	running, 1
		CALL	Reselect
		MOV	AX, serSeg
		MOV	DS, AX
		MOV	BX, serCtrlA
		MOV	BYTE PTR [BX], 1	; WR1: interrupt when it can send
		MOV	BYTE PTR [BX], 2
		IN	AL, 2
		AND	AL, 0FEH
		OUT	2, AL			; let IR0 through
		MOV	BX, serDataA
		MOV	BYTE PTR [BX], 0FFH	; the first dummy byte starts it
		RET
StartIrq	ENDP

; IrqOff (interrupts off): the serial chip's interrupts off, the DAC to
; the middle (silence), IR0's mask bit and vector as they were before.
; Called from the interrupt routines too (through Reselect): the dummy
; byte they still send afterwards just goes out without an interrupt.
; Uses AX, BX, DS.
IrqOff		PROC	NEAR
		MOV	AX, serSeg
		MOV	DS, AX
		MOV	BX, serCtrlA
		MOV	BYTE PTR [BX], 1	; WR1: no interrupts
		MOV	BYTE PTR [BX], 0
		MOV	BYTE PTR [BX], 28H	; reset the send interrupt
		MOV	BYTE PTR [BX], 38H	; end of interrupt
		MOV	AX, dacSeg
		MOV	DS, AX
		MOV	BX, dacSound
		MOV	BYTE PTR [BX], 80H
		IN	AL, 2
		AND	AL, 0FEH
		MOV	AH, oldMask
		AND	AH, 1
		OR	AL, AH
		OUT	2, AL
		XOR	AX, AX
		MOV	DS, AX
		MOV	BX, 80H
		MOV	AX, oldOff
		MOV	[BX], AX
		MOV	AX, oldSeg
		MOV	[BX+2], AX
		MOV	running, 0
		RET
IrqOff		ENDP

; Reselect (interrupts off, the interrupt on): points IR0 at the
; routine for what plays now (isrTab), or IrqOff when nothing does.
; Keeps AX and BX (the routines call it with a sample in AL); uses DS.
Reselect	PROC	NEAR
		PUSH	AX
		PUSH	BX
		XOR	BX, BX
		CMP	v0On, 0
		JE	RsV1
		OR	BL, 2
		CMP	v0Tab, 0
		JE	RsV1
		OR	BL, 16
RsV1:		CMP	v1On, 0
		JE	RsTone
		OR	BL, 4
		CMP	v1Tab, 0
		JE	RsTone
		OR	BL, 32
RsTone:		CMP	toneLeft, 0
		JE	RsPick
		OR	BL, 8
RsPick:		OR	BX, BX
		JNZ	RsSet
		CALL	IrqOff
		JMP	RsDone
RsSet:		MOV	AX, isrTab[BX]
		XOR	BX, BX
		MOV	DS, BX
		MOV	BX, 80H			; vector 20H (IR0)
		MOV	[BX], AX
		MOV	[BX+2], CS
RsDone:		POP	BX
		POP	AX
		RET
Reselect	ENDP

; StopIfIdle (interrupts off): after a voice or tone was stopped: the
; right routine again, or the interrupt off. Uses AX, BX, DS.
StopIfIdle	PROC	NEAR
		CMP	running, 0
		JE	SyDone
		CALL	Reselect
SyDone:		RET
StopIfIdle	ENDP

; ---------- GsOpen (count) ----------
; Gets the sound ready: timer 2 to "count" (sample rate about 517500 /
; count), the serial chip to async x1, 8N1, sender on, receiver off,
; DTR and RTS off, no interrupts yet; the volume tables; the DTMF chip
; quiet with its volume DAC up and voice mode (PC0) on; the DAC slowly
; up to the middle (silence). Nothing plays and no interrupt runs until
; GsPlay or GsTone. Does nothing if it is open already.
GSOPEN		PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		CMP	isOpen, 0
		JE	GoNew
		JMP	GoDone
GoNew:		MOV	CX, [BP+4]		; count
		CMP	CX, 20			; at most about 26 kHz
		JAE	GoCount
		MOV	CX, 20
GoCount:	MOV	DX, 7			; 517500 = 7E57CH
		MOV	AX, 0E57CH
		DIV	CX
		MOV	rateHz, AX
		PUSHF
		CLI
		MOV	v0On, 0
		MOV	v1On, 0
		MOV	toneLeft, 0
		MOV	running, 0
		XOR	AX, AX			; IR0 as it is now: StartIrq takes
		MOV	DS, AX			; it, IrqOff gives it back
		MOV	BX, 80H
		MOV	AX, [BX]
		MOV	oldOff, AX
		MOV	AX, [BX+2]
		MOV	oldSeg, AX
		IN	AL, 2
		MOV	oldMask, AL
		MOV	AL, 0B6H		; timer 2: low, high byte, mode 3
		OUT	0EH, AL
		MOV	AL, CL
		OUT	0CH, AL
		MOV	AL, CH
		OUT	0CH, AL
		MOV	AX, serSeg
		MOV	DS, AX
		MOV	BX, serCtrlA
		MOV	BYTE PTR [BX], 18H	; channel reset
		NOP
		NOP
		NOP
		NOP
		MOV	BYTE PTR [BX], 4	; WR4: x1, 1 stop bit, no parity
		MOV	BYTE PTR [BX], 4
		MOV	BYTE PTR [BX], 3	; WR3: receiver off
		MOV	BYTE PTR [BX], 0C0H
		MOV	BYTE PTR [BX], 5	; WR5: 8 bits, sender on, DTR RTS off
		MOV	BYTE PTR [BX], 68H
		MOV	BYTE PTR [BX], 1	; WR1: no interrupts (yet)
		MOV	BYTE PTR [BX], 0
		POPF
		MOV	AX, v0Lvl
		MOV	BX, OFFSET CGROUP:vol0
		CALL	FillVol
		MOV	AX, v1Lvl
		MOV	BX, OFFSET CGROUP:vol1
		CALL	FillVol
		MOV	AX, mdmSeg
		MOV	DS, AX
		MOV	BX, mdmPortB
		MOV	BYTE PTR [BX], 0FFH	; no digit
		MOV	AX, dacSeg
		MOV	DS, AX
		MOV	BX, dacVolume
		MOV	AL, toneVol
		MOV	[BX], AL
		MOV	AX, mdmSeg
		MOV	DS, AX
		MOV	BX, mdmCtrl
		MOV	BYTE PTR [BX], 1	; PC0 on (voice mode)
		MOV	AX, 8000H		; DAC from 0 up to 128
		CALL	Ramp
		MOV	isOpen, 1
GoDone:		POP	DS
		POP	BP
		RET	2
GSOPEN		ENDP

; ---------- GsClose ----------
; Stops everything: voices, tone, the interrupt (IR0 vector and mask as
; they were before GsOpen), resets the serial chip, ramps the DAC down
; and leaves the sound hardware as the PROM does. Call it before the
; program ends, every way it can end. Safe to call more than once.
GSCLOSE		PROC	NEAR
		PUSH	DS
		CMP	isOpen, 0
		JE	GcSafe
		PUSHF
		CLI
		MOV	v0On, 0
		MOV	v1On, 0
		MOV	toneLeft, 0
		CMP	running, 0
		JE	GcIdle
		CALL	IrqOff
GcIdle:		MOV	AX, serSeg
		MOV	DS, AX
		MOV	BX, serCtrlA
		MOV	BYTE PTR [BX], 18H	; channel reset
		POPF
		MOV	AX, 0080H		; DAC from 128 down to 0
		CALL	Ramp
		MOV	isOpen, 0
GcSafe:		CALL	Safe
		POP	DS
		RET
GSCLOSE		ENDP

; FUNCTION GsRate: INTEGER   samples a second, 0 if not open
GSRATE		PROC	NEAR
		XOR	AX, AX
		CMP	isOpen, 0
		JE	GrDone
		MOV	AX, rateHz
GrDone:		RET
GSRATE		ENDP

; FUNCTION GsRunning: INTEGER   1 while the interrupt is on
GSRUNNING	PROC	NEAR
		MOV	AL, running
		XOR	AH, AH
		RET
GSRUNNING	ENDP

; FUNCTION GsVersion: INTEGER   10000 = 1.0.0
GSVERSION	PROC	NEAR
		MOV	AX, gsVer
		RET
GSVERSION	ENDP

; ---------- GsPlay (voice, bSeg, bOff, len, loop) ----------
; Plays len bytes from bSeg:bOff on voice 0 or 1 (any other number =
; voice 1), from the start, in the background. loop <> 0: over and over
; until GsStop. Whatever that voice played before stops. The bytes must
; stay where they are while they play.
GSPLAY		PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		CMP	isOpen, 0		; (far jumps: GpOut is out of
		JNE	GpOpen			; a short jump's reach)
		JMP	GpOut
GpOpen:		CMP	WORD PTR [BP+6], 0	; len
		JNE	GpLen
		JMP	GpOut
GpLen:		MOV	AX, [BP+8]		; bOff
		MOV	DX, AX
		AND	DX, 0FH			; DX = offset 0-15
		MOV	CL, 4
		SHR	AX, CL
		ADD	AX, [BP+10]		; AX = segment
		MOV	CX, DX
		ADD	CX, [BP+6]		; CX = end
		MOV	BL, 0
		CMP	WORD PTR [BP+4], 0	; loop
		JE	GpLoop
		MOV	BL, 1
GpLoop:		PUSHF
		CLI
		CMP	WORD PTR [BP+12], 0	; voice
		JNE	GpV1
		MOV	v0On, 0
		MOV	v0Seg, AX
		MOV	v0Pos, DX
		MOV	v0Start, DX
		MOV	v0End, CX
		MOV	v0Loop, BL
		MOV	v0On, 1
		JMP	GpGo
GpV1:		MOV	v1On, 0
		MOV	v1Seg, AX
		MOV	v1Pos, DX
		MOV	v1Start, DX
		MOV	v1End, CX
		MOV	v1Loop, BL
		MOV	v1On, 1
GpGo:		CALL	StartIrq
		POPF
GpOut:		POP	DS
		POP	BP
		RET	10
GSPLAY		ENDP

; ---------- GsStop (voice) ----------
; Stops voice 0 or 1; any other number (gsBoth = 2) stops both.
GSSTOP		PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		PUSHF
		CLI
		MOV	AX, [BP+4]
		CMP	AX, 1
		JE	GtV1
		MOV	v0On, 0
		CMP	AX, 0
		JE	GtCheck
GtV1:		MOV	v1On, 0
GtCheck:	CALL	StopIfIdle
		POPF
		POP	DS
		POP	BP
		RET	2
GSSTOP		ENDP

; ---------- GsStopSound (bSeg, bOff) ----------
; Stops any voice playing the sound that starts at bSeg:bOff (GsFree
; calls this before it gives the memory back).
GSSTOPSOUND	PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		MOV	AX, [BP+4]		; bOff
		MOV	CL, 4
		SHR	AX, CL
		ADD	AX, [BP+6]		; the segment GsPlay keeps
		PUSHF
		CLI
		CMP	v0Seg, AX
		JNE	SsV1
		MOV	v0On, 0
SsV1:		CMP	v1Seg, AX
		JNE	SsCheck
		MOV	v1On, 0
SsCheck:	CALL	StopIfIdle
		POPF
		POP	DS
		POP	BP
		RET	4
GSSTOPSOUND	ENDP

; FUNCTION GsPlaying (voice): INTEGER   1 if voice 0 / 1 plays; any
; other number: 1 if either does
GSPLAYING	PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		MOV	BX, [BP+4]
		MOV	AL, v0On
		CMP	BX, 0
		JE	GyDone
		MOV	AL, v1On
		CMP	BX, 1
		JE	GyDone
		OR	AL, v0On
GyDone:		XOR	AH, AH
		POP	BP
		RET	2
GSPLAYING	ENDP

; ---------- GsVolume (voice, level) ----------
; Volume of voice 0 or 1 (any other number: both): 0 silent .. 8 as the
; sound is .. 16 twice as loud (clips). Kept for the next GsOpen too.
; Level 2 (25 percent, the start value) is the fast one: the routines
; divide by 4 with two shifts instead of using the volume table.
GSVOLUME	PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		MOV	AX, [BP+4]		; level
		CMP	AX, 0
		JGE	GvLow
		XOR	AX, AX
GvLow:		CMP	AX, 16
		JLE	GvHigh
		MOV	AX, 16
GvHigh:		PUSH	DS
		XOR	CL, CL			; CL = 1: needs the volume table
		CMP	AX, 2
		JE	GvFast
		INC	CL
GvFast:		MOV	DX, [BP+6]		; voice
		CMP	DX, 1
		JE	GvV1
		MOV	v0Lvl, AX
		MOV	BX, OFFSET CGROUP:vol0
		PUSH	AX
		PUSH	CX
		CALL	FillVol
		POP	CX
		POP	AX
		MOV	v0Tab, CL
		CMP	WORD PTR [BP+6], 0
		JE	GvDone
GvV1:		MOV	v1Lvl, AX
		MOV	BX, OFFSET CGROUP:vol1
		PUSH	CX
		CALL	FillVol
		POP	CX
		MOV	v1Tab, CL
GvDone:		PUSHF				; the right routine for it
		CLI
		CALL	StopIfIdle
		POPF
		POP	DS
		POP	BP
		RET	4
GSVOLUME	ENDP

; ---------- GsTone (digit, ms) ----------
; A DTMF tone from the modem's tone chip: digit 0-9, 10 = *, 11 = #
; (any other number: tone off). ms > 0: it stops by itself after that
; many milliseconds (counted by the sample interrupt, which runs for
; it); ms = 0: it plays until GsToneOff or the next GsTone, and costs
; no CPU time at all.
GSTONE		PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		CMP	isOpen, 0
		JNE	GnOpen
		JMP	GnOut
GnOpen:		MOV	BX, [BP+6]		; digit
		CMP	BX, 11
		JBE	GnDigit
		CALL	ToneOff
		JMP	GnOut
GnDigit:	MOV	CL, digTab[BX]
		OR	CL, 80H
		PUSHF
		CLI
		MOV	AX, mdmSeg
		MOV	DS, AX
		MOV	BX, mdmPortB
		MOV	[BX], CL
		MOV	AX, [BP+4]		; ms
		CMP	AX, 0
		JG	GnTimed
		MOV	toneLeft, 0		; held
		CALL	StopIfIdle
		JMP	GnDone
GnTimed:	MUL	rateHz			; samples = ms * rate / 1000
		CMP	DX, 1000
		JB	GnDiv
		MOV	AX, 0FFFFH
		JMP	GnSet
GnDiv:		MOV	CX, 1000
		DIV	CX
		OR	AX, AX
		JNZ	GnSet
		INC	AX
GnSet:		MOV	toneLeft, AX
		CALL	StartIrq
GnDone:		POPF
GnOut:		POP	DS
		POP	BP
		RET	4
GSTONE		ENDP

; ToneOff: no digit, no timed tone, the interrupt off if that was all.
; Uses AX, BX, DS.
ToneOff		PROC	NEAR
		PUSHF
		CLI
		MOV	AX, mdmSeg
		MOV	DS, AX
		MOV	BX, mdmPortB
		MOV	BYTE PTR [BX], 0FFH
		MOV	toneLeft, 0
		CALL	StopIfIdle
		POPF
		RET
ToneOff		ENDP

; ---------- GsToneOff ----------
GSTONEOFF	PROC	NEAR
		PUSH	DS
		CMP	isOpen, 0
		JE	GfOut
		CALL	ToneOff
GfOut:		POP	DS
		RET
GSTONEOFF	ENDP

; FUNCTION GsToneBusy: INTEGER   1 while a timed tone still plays
GSTONEBUSY	PROC	NEAR
		XOR	AX, AX
		CMP	toneLeft, 0
		JE	GbDone
		INC	AX
GbDone:		RET
GSTONEBUSY	ENDP

; ---------- GsToneVol (level) ----------
; The DTMF tones' volume DAC, 0-255 (255 at the start).
GSTONEVOL	PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	DS
		MOV	AL, [BP+4]
		MOV	toneVol, AL
		CMP	isOpen, 0
		JE	GvOut
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacVolume
		MOV	[BX], AL
GvOut:		POP	DS
		POP	BP
		RET	2
GSTONEVOL	ENDP

; ---------- GsSetName (VAR s: BYTES; n; VAR name: BYTES) ----------
; name := the n characters of s with a length byte in front, the way
; OsAttach wants a path: GsSetName ('Boom~Data~', 10, name).
GSSETNAME	PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	SI
		PUSH	DI
		PUSH	DS
		PUSH	ES
		MOV	CX, [BP+8]		; n
		CMP	CX, 0
		JGE	SnLow
		XOR	CX, CX
SnLow:		CMP	CX, 63
		JLE	SnHigh
		MOV	CX, 63
SnHigh:		LES	DI, DWORD PTR [BP+4]	; name
		LDS	SI, DWORD PTR [BP+10]	; s
		CLD
		MOV	AL, CL
		STOSB
		REP	MOVSB
		POP	ES
		POP	DS
		POP	DI
		POP	SI
		POP	BP
		RET	10
GSSETNAME	ENDP

; ---------- GsConvInit, GsConv ----------
; Rate conversion for gsfile.pas, a chunk of the file at a time:
; GsConvInit, then for each chunk
;   out := GsConv (sSeg, sOff, sLen, dSeg, dOff, dLen, step)
; copies source bytes to the sound, stepping through the source by
; step / 256 a byte (256 = every byte), until the chunk is used up or
; the sound has dLen bytes. Returns the bytes in the sound so far.
GSCONVINIT	PROC	NEAR
		MOV	cvI, 0
		MOV	cvF, 0
		MOV	cvOut, 0
		RET
GSCONVINIT	ENDP

GSCONV		PROC	NEAR
		PUSH	BP
		MOV	BP, SP
		PUSH	SI
		PUSH	DI
		PUSH	DS
		PUSH	ES
		MOV	AX, [BP+8]		; dOff
		MOV	DI, AX
		AND	DI, 0FH
		MOV	CL, 4
		SHR	AX, CL
		ADD	AX, [BP+10]		; dSeg
		MOV	ES, AX			; ES:DI = the sound, normalised
		MOV	cvBase, DI
		MOV	AX, DI
		ADD	AX, [BP+6]		; + dLen
		MOV	cvEnd, AX
		ADD	DI, cvOut
		MOV	AX, [BP+4]		; step
		MOV	DH, AL			; DH = step fraction
		MOV	CL, AH
		XOR	CH, CH			; CX = whole steps
		MOV	DL, cvF
		MOV	BX, cvI
		MOV	SI, [BP+14]		; sOff
		MOV	DS, [BP+16]		; sSeg
		MOV	BP, [BP+12]		; BP = sLen (parameters are read)
		CLD
CvNext:		CMP	DI, cvEnd
		JAE	CvDone
		CMP	BX, BP
		JAE	CvDone
		MOV	AL, [BX+SI]
		STOSB
		ADD	DL, DH
		ADC	BX, CX
		JMP	CvNext
CvDone:		CMP	BX, BP
		JB	CvKeep
		SUB	BX, BP			; on into the next chunk
CvKeep:		MOV	cvI, BX
		MOV	cvF, DL
		SUB	DI, cvBase
		MOV	cvOut, DI
		MOV	AX, DI
		POP	ES
		POP	DS
		POP	DI
		POP	SI
		POP	BP
		RET	14
GSCONV		ENDP

; ---------- the interrupts ----------
; One routine for each state, so a routine checks nothing it doesn't
; need. The state: which voices play (A = voice 0, B = voice 1), each
; one fast (f: volume 2 = 25 percent, divided by 4 with two shifts) or
; through its volume table (t: any other volume), and whether a timed
; tone (T) counts down. When a voice ends, a tone runs out, or a call
; changes what plays or a volume, Reselect points IR0 at the routine
; for the new state (or switches the interrupt off); the routine that
; is running still finishes its sample.
; Each sample: the next byte of each voice, its volume, added (clipped
; where it can overflow), to the DAC; then the next dummy byte to the
; serial chip and the PIC's end of interrupt. The 8274 gets no end of
; interrupt (38H) of its own with each sample: tested on a real Compass,
; it isn't needed, and it would cost about 19 clocks.
; The DAC and the serial chip are reached through one segment (DFE4:
; DAC at 2, serial data at 0C0H). With volume tables a sample
; takes about 320 clocks for one voice and 425 for two (measured).

; End0, End1 (from the routines, BX = past the end): looping, BX back
; to the start; otherwise the voice is off, AL = 128 (silence) and
; Reselect. Keep AH.
End0		PROC	NEAR
		CMP	v0Loop, 0
		JE	E0Off
		MOV	BX, v0Start
		RET
E0Off:		MOV	v0On, 0
		MOV	AL, 128
		CALL	Reselect
		RET
End0		ENDP

End1		PROC	NEAR
		CMP	v1Loop, 0
		JE	E1Off
		MOV	BX, v1Start
		RET
E1Off:		MOV	v1On, 0
		MOV	AL, 128
		CALL	Reselect
		RET
End1		ENDP

; ToneEnd: the timed tone is over: no digit, Reselect. Uses BX, DS.
ToneEnd		PROC	NEAR
		MOV	BX, mdmSeg
		MOV	DS, BX
		MOV	BX, mdmPortB
		MOV	BYTE PTR [BX], 0FFH
		CALL	Reselect
		RET
ToneEnd		ENDP

; voice 1 fast
IsrBf		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdBf:		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I1End1
I1Keep1:	MOV	v1Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		ADD	AL, 96			; = 128 + (byte - 128) / 4
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I1End1:		CALL	End1
		JMP	I1Keep1
IsrBf		ENDP

; the same with a timed tone counting down
IsrBfT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I1TEnd
		JMP	BdBf
I1TEnd:		CALL	ToneEnd
		JMP	BdBf
IsrBfT	ENDP

; voice 1 through its table
IsrBt		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdBt:		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I2End1
I2Keep1:	MOV	v1Pos, BX
		MOV	BX, OFFSET CGROUP:vol1
		XLAT	vol1			; CS:vol1[AL], signed
		XOR	AL, 80H			; signed -> DAC level
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I2End1:		CALL	End1
		JMP	I2Keep1
IsrBt		ENDP

; the same with a timed tone counting down
IsrBtT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I2TEnd
		JMP	BdBt
I2TEnd:		CALL	ToneEnd
		JMP	BdBt
IsrBtT	ENDP

; voice 0 fast
IsrAf		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAf:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I3End0
I3Keep0:	MOV	v0Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		ADD	AL, 96			; = 128 + (byte - 128) / 4
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I3End0:		CALL	End0
		JMP	I3Keep0
IsrAf		ENDP

; the same with a timed tone counting down
IsrAfT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I3TEnd
		JMP	BdAf
I3TEnd:		CALL	ToneEnd
		JMP	BdAf
IsrAfT	ENDP

; voice 0 fast and voice 1 fast
IsrAfBf		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAfBf:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I4End0
I4Keep0:	MOV	v0Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		MOV	AH, AL
		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I4End1
I4Keep1:	MOV	v1Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		ADD	AL, AH			; both 0-63: no clipping
		ADD	AL, 64			; = 128 + both signed
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I4End0:		CALL	End0
		JMP	I4Keep0
I4End1:		CALL	End1
		JMP	I4Keep1
IsrAfBf		ENDP

; the same with a timed tone counting down
IsrAfBfT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I4TEnd
		JMP	BdAfBf
I4TEnd:		CALL	ToneEnd
		JMP	BdAfBf
IsrAfBfT	ENDP

; voice 0 fast and voice 1 through its table
IsrAfBt		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAfBt:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I5End0
I5Keep0:	MOV	v0Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		SUB	AL, 32			; signed
		MOV	AH, AL
		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I5End1
I5Keep1:	MOV	v1Pos, BX
		MOV	BX, OFFSET CGROUP:vol1
		XLAT	vol1			; CS:vol1[AL], signed
		ADD	AL, AH
		JO	I5Clip
I5Mix:		XOR	AL, 80H			; signed -> DAC level
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I5End0:		CALL	End0
		JMP	I5Keep0
I5End1:		CALL	End1
		JMP	I5Keep1
I5Clip:		MOV	AL, 7FH			; both the same sign: clip
		OR	AH, AH
		JNS	I5Mix
		MOV	AL, 80H
		JMP	I5Mix
IsrAfBt		ENDP

; the same with a timed tone counting down
IsrAfBtT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I5TEnd
		JMP	BdAfBt
I5TEnd:		CALL	ToneEnd
		JMP	BdAfBt
IsrAfBtT	ENDP

; voice 0 through its table
IsrAt		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAt:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I6End0
I6Keep0:	MOV	v0Pos, BX
		MOV	BX, OFFSET CGROUP:vol0
		XLAT	vol0			; CS:vol0[AL], signed
		XOR	AL, 80H			; signed -> DAC level
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I6End0:		CALL	End0
		JMP	I6Keep0
IsrAt		ENDP

; the same with a timed tone counting down
IsrAtT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I6TEnd
		JMP	BdAt
I6TEnd:		CALL	ToneEnd
		JMP	BdAt
IsrAtT	ENDP

; voice 0 through its table and voice 1 fast
IsrAtBf		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAtBf:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I7End0
I7Keep0:	MOV	v0Pos, BX
		MOV	BX, OFFSET CGROUP:vol0
		XLAT	vol0			; CS:vol0[AL], signed
		MOV	AH, AL
		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I7End1
I7Keep1:	MOV	v1Pos, BX
		SHR	AL, 1
		SHR	AL, 1
		SUB	AL, 32			; signed
		ADD	AL, AH
		JO	I7Clip
I7Mix:		XOR	AL, 80H			; signed -> DAC level
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I7End0:		CALL	End0
		JMP	I7Keep0
I7End1:		CALL	End1
		JMP	I7Keep1
I7Clip:		MOV	AL, 7FH			; both the same sign: clip
		OR	AH, AH
		JNS	I7Mix
		MOV	AL, 80H
		JMP	I7Mix
IsrAtBf		ENDP

; the same with a timed tone counting down
IsrAtBfT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I7TEnd
		JMP	BdAtBf
I7TEnd:		CALL	ToneEnd
		JMP	BdAtBf
IsrAtBfT	ENDP

; voice 0 through its table and voice 1 through its table
IsrAtBt		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
BdAtBt:		LDS	BX, DWORD PTR v0Pos
		MOV	AL, [BX]		; voice 0's sample
		INC	BX
		CMP	BX, v0End
		JAE	I8End0
I8Keep0:	MOV	v0Pos, BX
		MOV	BX, OFFSET CGROUP:vol0
		XLAT	vol0			; CS:vol0[AL], signed
		MOV	AH, AL
		LDS	BX, DWORD PTR v1Pos
		MOV	AL, [BX]		; voice 1's sample
		INC	BX
		CMP	BX, v1End
		JAE	I8End1
I8Keep1:	MOV	v1Pos, BX
		MOV	BX, OFFSET CGROUP:vol1
		XLAT	vol1			; CS:vol1[AL], signed
		ADD	AL, AH
		JO	I8Clip
I8Mix:		XOR	AL, 80H			; signed -> DAC level
		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	[BX], AL		; DFE4:0002
		MOV	BYTE PTR [BX+0BEH], 0FFH ; DFF0:0000 next dummy byte
		MOV	AL, 60H			; PIC: specific EOI, IR0
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
I8End0:		CALL	End0
		JMP	I8Keep0
I8End1:		CALL	End1
		JMP	I8Keep1
I8Clip:		MOV	AL, 7FH			; both the same sign: clip
		OR	AH, AH
		JNS	I8Mix
		MOV	AL, 80H
		JMP	I8Mix
IsrAtBt		ENDP

; the same with a timed tone counting down
IsrAtBtT	PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JZ	I8TEnd
		JMP	BdAtBt
I8TEnd:		CALL	ToneEnd
		JMP	BdAtBt
IsrAtBtT	ENDP

; a timed tone alone: count it, the DAC stays at silence
IsrT		PROC	FAR
		PUSH	AX
		PUSH	BX
		PUSH	DS
		DEC	toneLeft
		JNZ	ItOut
		CALL	ToneEnd
ItOut:		MOV	BX, dacSeg
		MOV	DS, BX
		MOV	BX, dacSound
		MOV	BYTE PTR [BX+0BEH], 0FFH
		MOV	AL, 60H
		OUT	0, AL
		POP	DS
		POP	BX
		POP	AX
		IRET
IsrT		ENDP

CODE		ENDS
		END
