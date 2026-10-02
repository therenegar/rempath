.intel_syntax noprefix
.code16
.arch i8086
.section .text
.global _start

_start:
    cld
    # DOS enters an EXE with DS=ES=PSP.
    mov ax, ds
    mov cs:[psp_seg], ax
    mov ax, cs
    mov ds, ax

    # Parse one directory argument from PSP command tail.
    mov ax, cs:[psp_seg]
    mov es, ax
    xor cx, cx
    mov cl, byte ptr es:[0x80]
    mov si, 0x81

parse_skip_leading:
    cmp cx, 0
    je usage_error
    mov al, byte ptr es:[si]
    cmp al, ' '
    je parse_lead_one
    cmp al, 9
    jne parse_start
parse_lead_one:
    inc si
    dec cx
    jmp parse_skip_leading

parse_start:
    mov di, offset target
    xor bx, bx
    cmp byte ptr es:[si], '"'
    jne parse_unquoted
    inc si
    dec cx
parse_quoted_loop:
    cmp cx, 0
    je parse_done
    mov al, byte ptr es:[si]
    cmp al, '"'
    je parse_done
    cmp bx, 126
    jae arg_too_long
    call upper_al
    mov byte ptr [di], al
    inc di
    inc bx
    inc si
    dec cx
    jmp parse_quoted_loop

parse_unquoted:
    cmp cx, 0
    je parse_done
    mov al, byte ptr es:[si]
    cmp bx, 126
    jae arg_too_long
    call upper_al
    mov byte ptr [di], al
    inc di
    inc bx
    inc si
    dec cx
    jmp parse_unquoted

parse_done:
    # Trim trailing spaces/tabs.
parse_trim_space:
    cmp bx, 0
    je usage_error
    mov si, offset target
    add si, bx
    dec si
    mov al, byte ptr [si]
    cmp al, ' '
    je parse_trim_one
    cmp al, 9
    jne parse_trim_slash
parse_trim_one:
    dec bx
    jmp parse_trim_space

parse_trim_slash:
    # Ignore trailing backslashes except for drive roots (X:\).
    cmp bx, 1
    jbe parse_ready
    mov si, offset target
    add si, bx
    dec si
    cmp byte ptr [si], '\\'
    jne parse_ready
    cmp bx, 3
    jne parse_strip_slash
    cmp byte ptr target+1, ':'
    je parse_ready
parse_strip_slash:
    dec bx
    jmp parse_trim_slash

parse_ready:
    cmp bx, 0
    je usage_error
    mov cs:[target_len], bx
    mov si, offset target
    add si, bx
    mov byte ptr [si], 0

    # 4DOS has a resident API which returns the PSP for the current shell
    # invocation.  This is more reliable than PSP:16 for swapped 4DOS.
    mov ax, 0xD44D
    xor bh, bh
    int 0x2F
    cmp ax, 0x44DD
    jne use_dos_parent
    or cx, cx
    jz use_dos_parent
    mov ax, cx
    mov cs:[shell_psp], ax
    jmp have_shell_psp

use_dos_parent:
    # Restore our data segment after the multiplex call.
    mov ax, cs
    mov ds, ax
    mov ax, cs:[psp_seg]
    mov es, ax
    mov ax, word ptr es:[0x16]
    or ax, ax
    jz env_error
    mov cs:[shell_psp], ax

have_shell_psp:
    mov ax, cs
    mov ds, ax
    mov ax, cs:[shell_psp]
    mov es, ax
    mov ax, word ptr es:[0x2C]
    or ax, ax
    jz env_error
    mov cs:[env_seg], ax

    # Obtain the allocated size of the environment from its MCB.  We use
    # this when compacting so every variable after PATH stays contiguous.
    mov dx, ax
    dec ax
    mov es, ax
    mov cx, word ptr es:[3]       # MCB size in paragraphs
    cmp cx, 0
    je env_error
    cmp cx, 0x1000                # environment blocks must fit below 64K
    jae env_error
    mov ax, cx
    mov cl, 4
    shl ax, cl
    mov cs:[env_size], ax

    mov ax, dx
    mov es, ax                    # ES = shell environment
    xor di, di

find_env_var:
    cmp di, cs:[env_size]
    jae path_missing
    mov al, byte ptr es:[di]
    or al, al
    jz path_missing

    # PATH=, case-insensitive.
    mov si, di
    mov al, byte ptr es:[si]
    call upper_al
    cmp al, 'P'
    jne next_env_var
    mov al, byte ptr es:[si+1]
    call upper_al
    cmp al, 'A'
    jne next_env_var
    mov al, byte ptr es:[si+2]
    call upper_al
    cmp al, 'T'
    jne next_env_var
    mov al, byte ptr es:[si+3]
    call upper_al
    cmp al, 'H'
    jne next_env_var
    cmp byte ptr es:[si+4], '='
    jne next_env_var

    add si, 5
    mov cs:[path_start], si
    mov byte ptr cs:[removed_count], 0
    jmp scan_component

next_env_var:
next_env_char:
    cmp di, cs:[env_size]
    jae path_missing
    cmp byte ptr es:[di], 0
    je next_env_after_nul
    inc di
    jmp next_env_char
next_env_after_nul:
    inc di
    jmp find_env_var

scan_component:
    mov bx, si                    # BX = component start
    mov di, si                    # DI = component end
find_component_end:
    cmp di, cs:[env_size]
    jae env_error
    mov al, byte ptr es:[di]
    cmp al, ';'
    je component_end_found
    or al, al
    jz component_end_found
    inc di
    jmp find_component_end

component_end_found:
    push si
    push di
    call component_matches
    pop di
    pop si
    jc component_keep

    inc byte ptr cs:[removed_count]

    # Choose source and destination for deleting this PATH component.
    # Internal component: remove component plus following semicolon.
    # Final component: remove the preceding semicolon instead, if any.
    cmp byte ptr es:[di], ';'
    jne remove_final
    mov dx, bx                    # destination
    mov si, di
    inc si                        # source after following ';'
    jmp remove_shift

remove_final:
    mov si, di                    # source = PATH terminating NUL
    mov dx, bx                    # destination = component start
    cmp bx, cs:[path_start]
    je remove_shift
    dec dx                        # also remove preceding ';'

remove_shift:
    call shift_env_left
    mov si, dx                    # scan again at collapsed point
    cmp byte ptr es:[si], 0
    je scan_done
    jmp scan_component

component_keep:
    cmp byte ptr es:[di], 0
    je scan_done
    lea si, [di+1]
    jmp scan_component

scan_done:
    mov ax, cs
    mov ds, ax
    cmp byte ptr cs:[removed_count], 0
    je not_found
    mov dx, offset msg_removed
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

not_found:
    mov dx, offset msg_not_found
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

path_missing:
    mov ax, cs
    mov ds, ax
    mov dx, offset msg_path_missing
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C03
    int 0x21

env_error:
    mov ax, cs
    mov ds, ax
    mov dx, offset msg_env_error
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C03
    int 0x21

arg_too_long:
    mov ax, cs
    mov ds, ax
    mov dx, offset msg_too_long
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C02
    int 0x21

usage_error:
    mov ax, cs
    mov ds, ax
    mov dx, offset msg_usage
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C02
    int 0x21

# shift_env_left
# ES = environment segment
# SI = source offset, DX = destination offset, SI > DX
# Moves the entire remainder of the allocated environment block left so
# later environment variables and the post-environment data stay aligned.
# Returns DX unchanged.
shift_env_left:
    push ax
    push bx
    push cx
    push di
    push si
    push bp

    mov bp, si
    sub bp, dx                    # BP = bytes removed
    cmp bp, 0
    je shift_done

    mov cx, cs:[env_size]
    cmp si, cx
    jae shift_done
    sub cx, si                    # CX = bytes to copy
    mov di, dx
shift_copy_loop:
    cmp cx, 0
    je shift_clear_tail
    mov al, byte ptr es:[si]
    mov byte ptr es:[di], al
    inc si
    inc di
    dec cx
    jmp shift_copy_loop

shift_clear_tail:
    # DI now points to env_size - bytes_removed. Zero the vacated tail.
    mov cx, bp
    xor al, al
shift_zero_loop:
    cmp cx, 0
    je shift_done
    mov byte ptr es:[di], al
    inc di
    dec cx
    jmp shift_zero_loop

shift_done:
    pop bp
    pop si
    pop di
    pop cx
    pop bx
    pop ax
    ret

# component_matches
# ES = environment
# BX = component start, DI = component end (exclusive)
# DS = CS and target is uppercase/normalized.
# Returns CF=0 match, CF=1 mismatch.
component_matches:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp

    mov bp, bx
    mov dx, di

    # Trim spaces/tabs around component for comparison only.
comp_trim_left:
    cmp bp, dx
    jae comp_trim_right
    mov al, byte ptr es:[bp]
    cmp al, ' '
    je comp_trim_left_one
    cmp al, 9
    jne comp_trim_right
comp_trim_left_one:
    inc bp
    jmp comp_trim_left

comp_trim_right:
    cmp dx, bp
    jbe comp_strip_quotes
    mov si, dx
    dec si
    mov al, byte ptr es:[si]
    cmp al, ' '
    je comp_trim_right_one
    cmp al, 9
    jne comp_strip_quotes
comp_trim_right_one:
    dec dx
    jmp comp_trim_right

comp_strip_quotes:
    mov ax, dx
    sub ax, bp
    cmp ax, 2
    jb comp_strip_slash
    cmp byte ptr es:[bp], '"'
    jne comp_strip_slash
    mov si, dx
    dec si
    cmp byte ptr es:[si], '"'
    jne comp_strip_slash
    inc bp
    dec dx

comp_strip_slash:
    # Ignore trailing backslashes except X:\.
    mov ax, dx
    sub ax, bp
    cmp ax, 1
    jbe comp_len_ready
    mov si, dx
    dec si
    cmp byte ptr es:[si], '\\'
    jne comp_len_ready
    cmp ax, 3
    jne comp_do_strip
    cmp byte ptr es:[bp+1], ':'
    je comp_len_ready
comp_do_strip:
    dec dx
    jmp comp_strip_slash

comp_len_ready:
    mov cx, dx
    sub cx, bp
    cmp cx, cs:[target_len]
    jne comp_no_match

    mov si, offset target
comp_char_loop:
    cmp cx, 0
    je comp_match
    mov al, byte ptr es:[bp]
    call upper_al
    cmp al, byte ptr [si]
    jne comp_no_match
    inc bp
    inc si
    dec cx
    jmp comp_char_loop

comp_match:
    clc
    jmp comp_return
comp_no_match:
    stc
comp_return:
    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

upper_al:
    cmp al, 'a'
    jb upper_done
    cmp al, 'z'
    ja upper_done
    sub al, 32
upper_done:
    ret

psp_seg:        .word 0
shell_psp:      .word 0
env_seg:        .word 0
env_size:       .word 0
target_len:     .word 0
path_start:     .word 0
removed_count:  .byte 0

target:         .space 128, 0

msg_removed:      .ascii "REMPATH: directory removed from PATH.\r\n$"
msg_not_found:    .ascii "REMPATH: directory not found in PATH.\r\n$"
msg_path_missing: .ascii "REMPATH: PATH variable not found.\r\n$"
msg_env_error:    .ascii "REMPATH: unable to access shell environment.\r\n$"
msg_too_long:     .ascii "REMPATH: directory argument is too long.\r\n$"
msg_usage:        .ascii "Usage: REMPATH directory\r\n$"

.align 2
stack_space:     .space 1024, 0
stack_top:
