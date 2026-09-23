; =============================================================================
;   N Y C   B Y   N I G H T   -   a 512-byte x86 boot sector "OS"
; =============================================================================
;
;   The Brooklyn Bridge in front of the Manhattan skyline on a moonlit night,
;   with the East River below. After drawing the scene the "OS" runs forever
;   and keeps the city alive:
;
;     * the river ripples: its reflection is re-rendered every frame with
;       per-row jitter, and moonlight glitters on the water under the moon
;     * office windows switch on and off at random
;     * red aviation beacons on the three spires pulse in sync with the
;       heart in "I <3 NY"
;
;   Landmarks: One World Trade Center (tapered, with its spire ring), the
;   Empire State Building (setbacks, lit mooring mast, antenna), the Chrysler
;   Building (terraced crown, needle), the Brooklyn Bridge (floodlit granite
;   towers with gothic arches, catenary main cables, suspenders), plus about 50
;   procedurally generated buildings in three depth layers.
;
;   build:  nasm -f bin nyc.asm -o nyc.bin
;   run:    qemu-system-i386 -drive format=raw,file=nyc.bin
;
;   Needs a 386+ (imul r,imm / shifts by imm), VGA mode 13h, and a BIOS that
;   enters with IF=1 and DF=0 (SeaBIOS/QEMU, Bochs, real PCs).
;
; -----------------------------------------------------------------------------
;   How it fits in 510 bytes
; -----------------------------------------------------------------------------
;   Palette  8 linear gradient segments (count, packed dR|dG word, dB) are
;            walked twice: entries 0-127 at full brightness, 128-255 at half.
;            So "or al,0x80" turns any colour into its reflection. The segment
;            deltas are chosen so the accumulators wrap back to exactly 0 after
;            pass 1, so pass 2 needs no reset code.
;
;              0- 15  unlit windows (dark navy)    16- 31  lit windows
;             32-112  sky: zenith -> blue -> purple -> city glow
;             113     CROWN  warm white (moon, stars, crowns, cables, text)
;             114     RED    rewritten every frame (heart + beacons)
;             115     STONE  floodlit granite of the bridge
;             128-255 the same colours at half brightness (water)
;
;   Buildings   One routine (bldg) draws every procedural building, landmark
;               step and lit crown. Window pixels pick a random colour from
;               0-31, half of which are "off". Walls reuse dark sky colours
;               (atmospheric perspective: far layers are lighter).
;   Landmarks   Drawn spire-first: every step is 2 px wider and shorter than
;               the previous one and overpaints it (painter's algorithm). A
;               1-px-wide step gets a red beacon on top.
;   Sky/bridge  A per-pixel shader that paints the bridge and fills the sky
;               only into still-empty pixels. So the moon sits behind the
;               towers, and the BIOS-printed text keeps its letters while its
;               black background becomes sky.
;   Bridge      Sign-extending the low 7 bits of x gives v = distance to the
;               nearest cable low point (period 128 px, towers at x=64/192).
;               v^2 alone yields the parabolic cables, the tower columns and
;               the arch openings.
;   Water       Each row is copied from its mirror row above the horizon, with
;               a random 0-3 px shift and OR 0x80 (half brightness).
; =============================================================================

bits 16
org 0x7C00

H       equ 150             ; horizon: rows 0..149 city, 150..199 river
MX      equ 96              ; moon centre / radius   (MX >= 89 keeps the
MY      equ 38              ;  16-bit d^2 of every sky pixel from overflowing)
MR      equ 11
CROWN   equ 113             ; palette indices, see table above
RED     equ 114
STONE   equ 115
WALLT   equ 50              ; wall colour of the landmark towers (a sky blue)
Y_TT    equ 96              ; bridge: tower top row
Y_ARCH  equ 104             ;         top of the arch openings
Y_DECK  equ 128             ;         roadway (3 rows)
Y_LOW   equ 129             ;         lowest point of the main cables

start:
    mov ax, 0x13            ; VGA 320x200, 256 colours
    int 0x10
    push 0xA000
    pop es                  ; ES -> video memory for the whole program
    xor bx, bx              ; BX = R|G accumulators of the palette walk
    mov ds, bx              ; DS = 0 so our tables are addressable

; ------------------------------------------------------------------- palette
    mov dx, 0x3C8
    xor ax, ax              ; AL = start index 0, AH = B accumulator
    out dx, al
    inc dx                  ; 0x3C9 = DAC data
    mov cl, 2               ; pass 1: 8-bit accumulators >> 2 = 6-bit DAC
pal_pass:
    mov si, pal
pal_seg:
    lodsb
    mov ch, al              ; entries in this segment
pal_step:
    add bx, [si]            ; R and G in one packed 16-bit add
    add ah, [si+2]          ; B
    mov al, bl
    shr al, cl
    out dx, al
    mov al, bh
    shr al, cl
    out dx, al
    mov al, ah
    shr al, cl
    out dx, al
    dec ch
    jnz pal_step
    add si, 3
    cmp si, pal_end
    jb pal_seg
    inc cx                  ; pass 2 (CL=3): same walk at half brightness
    jpe pal_pass            ; CL=3 has even parity -> loop; CL=4 -> done

; ---------------------------------------------------------------- the city
    mov si, data
    call layer              ; far layer (tall, hazy)
landmark:
    lodsw                   ; bottom address of the spire column
    xchg ax, di
    mov cl, 1               ; start 1 px wide (CH is already 0)
.step:
    lodsb                   ; height of this step, 0 = end of landmark
    test al, al
    jz .next
    mov bh, al
    mov dh, WALLT
    mov bl, 1               ; windows on every other pixel/row
    cmp cl, 9
    ja .draw
    mov dh, CROWN           ; narrow parts (<= 9 px) are floodlit crowns
.draw:
    call bldg
    dec di                  ; next step: 1 px further left ...
    inc cx
    inc cx                  ; ... and 2 px wider
    jmp .step
.next:
    cmp si, landmarks_end
    jb landmark
    call layer              ; middle layer
    call layer              ; near layer (low, dark)

; --------------------------------------------------------------- I <3 NY
text:
    lodsb                   ; "\n I \x03 NY" via BIOS teletype
    mov bl, CROWN
    cmp al, 4               ; the heart (char 3) gets RED = CROWN+1
    jnc .print
    inc bx
.print:
    mov ah, 0x0E
    int 0x10
    cmp al, 'Y'
    jne text

; ----------------------------------------------- sky + bridge pixel shader
    push es
    pop ds                  ; DS = ES = video memory from here on
    xor di, di
shade:                      ; runs over all 64K (rows >= 150 get
    mov ax, di              ;  overwritten by the river anyway)
    xor dx, dx
    mov bx, 320
    div bx
    xchg ax, bx             ; BX = y, DX = x
    mov al, dl
    add al, al              ; AL = 2v, v = x sign-extended from 7 bits
    imul al                 ; AX = 4v^2, v = distance to cable low point
    cmp ax, 4*58*58
    jb .span                ; |v| < 58: between the towers
    cmp bl, Y_TT            ; tower column
    jb .sky
    sub ax, 4*60*60         ; |v| in 60..62 -> the two arch openings
    cmp ax, 4*(62*62-60*60)+1
    jae .stone
    lea ax, [bx-Y_ARCH]
    cmp al, Y_DECK-Y_ARCH
    jb .sky                 ; inside an arch: see through
.stone:
    mov al, STONE
    jmp .put
.span:
    shr ax, 9               ; v^2 / 128 = height of the cable above its low point
    add ax, bx
    sub ax, Y_LOW
    jl .sky                 ; above the cable
    mov al, CROWN
    jz .put                 ; on the cable: string of lights
    lea ax, [bx-Y_DECK]
    cmp al, 3
    jb .stone               ; roadway
    jge .sky                ; below the roadway
    test dl, 3
    jz .stone               ; suspender every 4 px
.sky:
    mov al, [di]
    test al, al
    jnz .put                ; something already drawn here: keep it
    lea ax, [bx-MY]
    imul ax, ax
    sub dx, MX
    imul dx, dx
    add ax, dx
    cmp ax, MR*MR
    mov al, CROWN
    jb .put                 ; moon
    call rand
    cmp ax, 150
    mov al, CROWN
    jb .put                 ; star (~0.2 %)
    xchg ax, bx             ; AL = y, BH = random
    shr bh, 5
    add al, bh              ; dither the gradient by 0..7 rows
    shr al, 1
    add al, 32              ; sky colour = 32 + (y + dither) / 2
.put:
    stosb
    test di, di
    jnz shade

; ------------------------------------------------ the OS: keep NYC alive
    push ax                 ; frame counter lives on the stack
main:
    hlt                     ; ~18.2 fps, paced by the BIOS timer tick
    mov dx, 0x3C8
    pop ax
    sub ah, 4               ; AH = -4*frame -> flash, then fade (6-bit DAC)
    push ax
    mov al, RED
    out dx, ax              ; 0x3C8 <- RED index, 0x3C9 <- R = AH
    inc dx
    mov al, 0
    out dx, al              ; G = 0
    out dx, al              ; B = 0
    mov di, H*320
.row:
    call rand               ; window flicker: poke one random address;
    xchg ax, bx             ;  if it holds a window colour (0..31),
    cmp byte [bx], 32       ;  give it a new random one (on/off/dim)
    jae .water
    call rand
    shr ax, 11
    mov [bx], al
.water:
    xchg ax, bx             ; AX = random again
    mov bl, ah
    and bx, 15              ; BX = glitter offset 0..15
    shr ax, 14              ; AX = ripple 0..3 px
    sub ax, di
    add ax, ((2*H-1)*320) & 0xFFFF
    xchg ax, si             ; SI = mirrored row (+ ripple)
    mov cx, 320
.px:
    lodsb
    or al, 0x80             ; half-brightness copy of the colour
    stosb
    loop .px
    mov byte [bx+di+MX-8-320], CROWN    ; moonlight glitter under the moon
    cmp di, 64000
    jb .row
    jmp main

; ------------------------------------------------------------ subroutines

; One layer of random buildings across the whole width.
; SI -> [wall colour, height mask, min height], advanced by 3.
layer:
    mov di, (H-1)*320
.bld:
    call rand
    mov bh, ah
    and bh, [si+1]
    add bh, [si+2]          ; height
    mov bl, al
    shr al, 4
    add al, 6
    cbw
    xchg ax, cx             ; width 6..21
    and bl, 2
    inc bx                  ; window pattern: dense (1) or sparse (3)
    mov dh, [si]
    call bldg
    add di, cx              ; the last one may wrap to the left edge,
    cmp di, H*320           ;  where it just looks like one more building
    jb .bld
    lodsw
    lodsb
    ret

; Draw a building. DI = bottom-left pixel, CX = width, BH = height,
; BL = window mask, DH = wall colour. Rows are counted from the horizon so
; window rows line up across the whole city. Keeps DI, CX, BX, SI.
bldg:
    push di
    mov dl, 1
.row:
    push di
    push cx
.px:
    mov ax, di              ; low byte of DI = x mod 64 (320 = 5*64)
    or al, dl
    and al, bl
    mov al, dh
    jnz .wall
    call rand
    shr ax, 11              ; window: random colour 0..31 (half are "off")
.wall:
    stosb
    loop .px
    pop cx
    pop di
    sub di, 320
    inc dx
    cmp dl, bh
    jbe .row
    loop .done              ; width 1 (a spire)? CX 1 -> 0 falls through:
    mov al, RED             ;  red aviation beacon on top
    stosb
.done:
    inc cx
    pop di
    ret

; 16-bit LCG. Full period since the multiplier = 1 mod 4 and the increment is odd.
; The high bits are the good ones.
rand:
    imul bp, bp, -91
    inc bp
    mov ax, bp
    ret

; ------------------------------------------------------------------- data
%macro PSEG 4               ; count, dR, dG, dB  (8-bit units, 6-bit DAC << 2)
    db %1
    dw ((%2) + 256*(%3)) & 0xFFFF
    db (%4) & 0xFF
%endmacro

pal:
    PSEG 16,    1,    1,    4   ;   0- 15 unlit windows
    PSEG 16,   14,   13,    8   ;  16- 31 lit windows
    PSEG 1,  -230, -214, -152   ;  32     sky zenith
    PSEG 40,    1,    1,    2   ;  33- 72 ... deep blue
    PSEG 40,    5,    2,    0   ;  73-112 ... purple -> salmon city glow
    PSEG 1,     0,  110,   60   ; 113     CROWN (250,240,180)
    db 1                        ; 114     RED placeholder (75,58,23), picked
    dw 18769                    ;         so the table sums to 0 mod 2^16;
    db 99                       ;         the main loop rewrites it
    db 13                       ; 115     STONE (148,132,100), then filler
    dw 19017
    db 77
pal_end:

data:
    db 56, 63, 24                                       ; far layer
    dw (H-1)*320 + 148                                  ; One World Trade Center
    db 127, 107, 1, 1, 1, 104, 100, 86, 72, 58, 44, 0   ;  spire, ring, taper
    dw (H-1)*320 + 236                                  ; Empire State Building
    db 120, 104, 102, 1, 92, 1, 89, 86, 83, 0           ;  antenna, mast, setbacks
    dw (H-1)*320 + 284                                  ; Chrysler Building
    db 104, 92, 88, 84, 80, 76, 70, 0                   ;  needle, terraced crown
landmarks_end:
    db 44, 31, 12                                       ; middle layer
    db 36, 15, 4                                        ; near layer
    db 10, " I ", 3, " NY"

    times 510-($-$$) db 0
    dw 0xAA55
