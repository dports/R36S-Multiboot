#!/bin/bash
[[ "$ghdebug" == "true" ]] && set -x

# amberelec ark pan4elec rocknix uos bookworm jammy noble plucky

if [[ "$1" == "testoses" ]]
then
    for i in amberelec ark pan4elec rocknix uos
    do
        ./buildimg.sh "$i" || exit 1
        sleep 5
    done
    exit 0
fi

function say {
    echo
    echo $@
}
function sayin {
    echo ► $@
}

u=$(id -u)
g=$(id -g)
imgname=R36S-Multiboot

StartDir=$(pwd)
BuildingImgFullPath=${StartDir}/building.img
[[ -f "$BuildingImgFullPath" ]] && rm "$BuildingImgFullPath"

for mp in $(mount | grep "$(pwd)" |cut -d' ' -f1)
do
    sudo umount "${mp}" && echo ${mp} was stll mounted || exit 1
done

[[ -d tmp ]] && rm -rf tmp || true
[[ -d tmp ]] && exit 1

for ld in $(losetup | grep "$(pwd)" |cut -d' ' -f1)
do
    echo
    sudo losetup -d ${ld} && echo ${ld} was stll attached to an image || exit 1
done

mkdir tmp

partcount=0
nextpartstart=16
bootsize=48
imgsizereq=32
storagesize=24

# shrink armbian sizes if building the big one
if [[ "$BuildImgEnv" == "github" ]]
then
    if [[ "$@" == *"bookworm jammy noble pluck"* ]] # anticipate never-ending ubuntu releases
    then
        say "Building the big one, reducing size requirements"
        # jammy+/sizereq is currently a symlink to bookworm/sizereq
        # so we can just change bookworm/sizereq
        echo 5120 > bookworm/sizereq
        #echo 512 > amberelec/sizereq
    fi
fi

for arg in "$@"; do
    thissizereq=0
    if [[ -f "$arg/bootsizereq" ]]
    then
        thissizereq=$(cat "$arg/bootsizereq")
        imgsizereq=$((imgsizereq + thissizereq))
    fi
    if [[ -f "$arg/sizereq" ]]
    then
        thissizereq=$(cat "$arg/sizereq")
        imgsizereq=$((imgsizereq + thissizereq))
    fi
done

imgsizereq=$((storagesize + imgsizereq))
imgsize=$((bootsize + imgsizereq + 16))

echo imgsize is $imgsize
echo bootsize is $bootsize

set -e

say make base image ${imgsize}MiB
ImgLodev=$(losetup -f)

fallocate -l ${imgsize}MiB ${BuildingImgFullPath}

sudo losetup -P ${ImgLodev} ${BuildingImgFullPath}

function refreshBuildimg {
    sync
    echo ► refresh ${ImgLodev}
    [[ ! -z "${ImgBootMnt}" ]] && echo ►► umount "${ImgBootMnt}" || true
    [[ ! -z "${ImgBootMnt}" ]] && sudo umount "${ImgBootMnt}" || true
    sudo losetup -d ${ImgLodev}
    sleep 3
    sync
    sudo losetup -P ${ImgLodev} ${BuildingImgFullPath}
    sleep 3
    [[ ! -z "${ImgBootMnt}" ]] && echo ►► mount ${ImgLodev}p1 "${ImgBootMnt}" || true
    [[ ! -z "${ImgBootMnt}" ]] && sudo mount ${ImgLodev}p1 "${ImgBootMnt}" || true
}

if [[ ! -d u-boot ]]
then
    say get u-boot
    mkdir u-boot
    cd u-boot
    wget https://github.com/R36S-Stuff/R36S-u-boot-builder/releases/download/v1/u-boot-r36s.tar
    cd ..
fi
cd u-boot
if [[ ! -f u-boot-r36s.tar ]]
then
    exit 1
fi
say add uboot
if [[ ! -d "sd_fuse" ]]
then
    mkdir sd_fuse
    tar xf u-boot-r36s.tar -C sd_fuse
fi
cd sd_fuse
chmod a+x ./sd_fusing.sh
./sd_fusing.sh ${ImgLodev} >/dev/null 2>&1
cd "${StartDir}"

say create partition table
sudo parted -s ${ImgLodev} mklabel msdos #|| echo

function newpart {
    local start=$nextpartstart
    local partsize=$1
    local end=$((start + partsize))
    local ptype=notset
    echo ► create from ${start}MiB to ${end}MiB
    [[ "$2" == "fat" ]] && local type=fat32 || true
    [[ "$2" == "ext4" ]] && local type=ext4 || true
    [[ "$2" == "exfat" ]] && local type=fat32 || true

    [[ $partcount == 0 ]] && ptype=primary || ptype=logical
    sudo parted -s ${ImgLodev} mkpart $ptype $type ${start}MiB ${end}MiB || true
    refreshBuildimg
    ls ${ImgLodev}p$((partcount + 1)) >/dev/null 2>&1 && partcount=$((partcount + 1)) || exit 1
    nextpartstart=${end}
    [[ "$ptype" == "logical" ]] && nextpartstart=$((nextpartstart+1)) || true

    if [[ "$2" == "fat" ]]
    then
        if [[ -z "$3" ]]
        then
            #echo
            echo ► format as fat
            sudo mkfs.vfat -F 32 ${ImgLodev}p${partcount} >/dev/null 2>&1
        else
            #echo
            echo ► format as fat with label $3
            sudo mkfs.vfat -F 32 -n $3 ${ImgLodev}p${partcount} >/dev/null 2>&1
        fi
    fi

    if [[ "$2" == "exfat" ]]
    then
        if [[ -z "$3" ]]
        then
            #echo
            echo ► format as exfat
            sudo mkfs.exfat ${ImgLodev}p${partcount} >/dev/null 2>&1
        else
            #echo
            echo ► format as fat with label $3
            sudo mkfs.exfat -L $3 ${ImgLodev}p${partcount} >/dev/null 2>&1
        fi
    fi

    if [[ "$2" == "ext4" ]]
    then
        if [[ -z "$3" ]]
        then
            #echo
            echo ► format as ext4
            sudo mkfs.ext4 ${ImgLodev}p${partcount} >/dev/null 2>&1
        else
            #echo
            echo ► format as ext4 with label $3
            sudo mkfs.ext4 -L $3 ${ImgLodev}p${partcount} >/dev/null 2>&1
        fi
    fi
    sync
    [[ "$3" == "returndev" ]] && return "${ImgLodev}p${partcount}" || true
}

say create boot partition
newpart ${bootsize} fat boot
ImgBootMnt="${StartDir}/tmp/boot.tmpmnt"
mkdir -p "${ImgBootMnt}"
sudo mount ${ImgLodev}p${partcount} "${ImgBootMnt}"
sleep 3

say fill boot partition
sudo cp -R commonbootfiles/* "${ImgBootMnt}"

## Build tar.xz
# tar --exclude="*/gb/*.zip" --exclude="*/bios/*" --exclude="*/00_*/*" --exclude="*/n64/*.zip" -c EZStorage_all > EZStorage_all.tar

sudo cp "${StartDir}/EZ/EZStorage_all.tar" "${ImgBootMnt}/EZStorage_all.tar"
sudo cp "${StartDir}/EZ/setup-ezstorage.sh" "${ImgBootMnt}/setup-ezstorage.sh"

function bootiniadd {
    echo "$@" | sudo tee --append "${ImgBootMnt}/boot.ini" >/dev/null
}

bootiniadd odroidgoa-uboot-config
bootiniadd ""
bootiniadd setenv boot2 $1
bootiniadd ""
bootiniadd 'if env exist Stickyboot2'
bootiniadd 'then'
bootiniadd '    setenv boot2 ${Stickyboot2}'
bootiniadd 'fi'
bootiniadd ""
for arg in "$@"; do
    thisbtn=$(cat $arg/bootbutton)
    bootiniadd if gpio input $thisbtn
    bootiniadd then
    bootiniadd "    setenv boot2 $arg"
    bootiniadd fi
    bootiniadd ""
done

bootiniadd 'if gpio input c4'
bootiniadd 'then'
bootiniadd '    setenv Stickyboot2 ${boot2}'
bootiniadd '    saveenv'
bootiniadd 'fi'
bootiniadd ""

bootiniadd 'echo booting ${boot2}'
bootiniadd 'mw.b 0x00800800 0 0x1000'
bootiniadd 'load mmc 1:1 0x00800800 boot.${boot2}.ini'
bootiniadd source 0x00800800

echo
cat "${ImgBootMnt}/boot.ini"

# need to setup extended part now that were mbr
epartstart=$nextpartstart
while true
do
    epartstart=$((epartstart+1))
    sudo parted -s ${ImgLodev} mkpart extended $epartstart 100% 2>&1 | grep "The closest location we can manage is" >/dev/null 2>&1 && continue || echo epart at $epartstart
    partcount=$((partcount+3))
    nextpartstart=$((nextpartstart+1))
    break
done

sleep 20
for arg in "$@"; do
    OsName=${arg}
    ThisImgName=${OsName}.img

    tmpmnts="${StartDir}/tmp/${OsName}.tmpmnts"
    mkdir -p "$tmpmnts"
    OSDir="${StartDir}/${OsName}"
    cd "${OSDir}"
    chmod a+x ./*.sh

    for step in get-image pre-install install-os post-install
    do
        echo
        [[ -f "./${step}.sh" ]] && echo Start: ${OsName}: ${step} || echo skipping ${step}...
        echo
        [[ -f "./${step}.sh" ]] && echo source ./${step}.sh  || continue
        echo
        source ./${step}.sh
        echo End: ${OsName}: ${step}
        echo
    done
    sync
    cd "${StartDir}"
done


if [[ "$@" == *"andr36oid"* ]] 
then
    sayin add android data partition
    sync
    sudo umount "${ImgBootMnt}"
    [[ -n "$AnDataSizeOverride" ]] && imgsize=$((imgsize + AnDataSizeOverride)) || imgsize=$((imgsize + 8192))
    sudo losetup -d $ImgLodev
    fallocate -l ${imgsize}MiB ${BuildingImgFullPath}
    sync
    sudo losetup -P ${ImgLodev} ${BuildingImgFullPath}
    sudo parted -s ${ImgLodev} resizepart 2 100%
    sudo mount ${ImgLodev}p1 "${ImgBootMnt}"
    [[ -n "$AnDataSizeOverride" ]] && npsz=$AnDataSizeOverride || npsz=8192
    sayin new $((npsz/1024))GiB partition
    newpart $npsz ext4 andata
fi

say create storage partition
newpart 8 exfat EZSTORAGE
Storagemount="${StartDir}/tmp/storage.tmpmnt"

say finalize image
sync
sudo umount "${ImgBootMnt}"
[[ -d commonStoragefiles ]] && sudo umount "${Storagemount}" || true
sudo losetup -d ${ImgLodev}
sync

[[ "$BuildImgEnv" == "github" ]] && OutImgNameNoExt=${imgname}-$(echo "$@" |sed 's| |-|g')-$GH_build_date || OutImgNameNoExt=${imgname}-$(echo "$@" |sed 's| |-|g')-$(TZ=America/New_York date +%Y-%m-%d-%H%M)

OutImg=${StartDir}/${OutImgNameNoExt}.img
OutImgXZ=${StartDir}/${OutImgNameNoExt}.img.xz
OutImg7z=${StartDir}/${OutImgNameNoExt}.img.xz.7z

echo ${OutImg}

mv ${BuildingImgFullPath} ${OutImg}
sync

if [[ "$BuildImgEnv" == "github" ]]
then
    fallocate --dig-holes ${OutImg}
    sayin comoressing with xz
    xz -z -7 -T0 ${OutImg}
    sayin splitting with 7z
    7z a -mx9 -md512m -mfb273 -mmt2 -v2000m ${OutImg7z} ${OutImgXZ}
    ls ${StartDir}/${imgname}-*
fi

sync
