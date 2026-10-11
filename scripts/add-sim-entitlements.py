#!/usr/bin/env python3
"""Embed entitlements into a simulator executable the way Xcode's linker does.

Simulator apps are signed ad hoc, and macOS refuses to start an ad hoc binary
whose *signature* carries entitlements like application-identifier. Xcode
therefore stores them in two sections of the executable instead
(__TEXT,__entitlements as XML and __TEXT,__ents_der as DER), which the
simulator reads. This adds those sections to an already linked arm64 binary,
using the unused space between the load commands and the first section.

Usage: add-sim-entitlements.py <executable> <entitlements.xml> <entitlements.der>
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
HEADER, SEGMENT, SECTION = 32, 72, 80


def main(path, xml_path, der_path):
    data = bytearray(open(path, "rb").read())
    blobs = [(b"__entitlements", open(xml_path, "rb").read()), (b"__ents_der", open(der_path, "rb").read())]

    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<6I", data, 0)
    if magic != 0xFEEDFACF:
        sys.exit("error: not a thin 64-bit Mach-O")

    text_cmd = text_vmaddr = None
    first_section = len(data)
    offset = HEADER
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", data, offset)
        if cmd == LC_SEGMENT_64:
            segname = bytes(data[offset + 8 : offset + 24]).rstrip(b"\0")
            vmaddr, _, fileoff = struct.unpack_from("<3Q", data, offset + 24)
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            if segname == b"__TEXT":
                if fileoff != 0:
                    sys.exit("error: __TEXT does not start at file offset 0")
                text_cmd, text_vmaddr = offset, vmaddr
            for i in range(nsects):
                section = offset + SEGMENT + i * SECTION
                name = bytes(data[section : section + 16]).rstrip(b"\0")
                if name in (b"__entitlements", b"__ents_der"):
                    sys.exit("error: entitlement sections already present")
                size, sect_off = struct.unpack_from("<QI", data, section + 40)
                if sect_off and size:
                    first_section = min(first_section, sect_off)
        offset += cmdsize
    if text_cmd is None:
        sys.exit("error: no __TEXT segment")

    added = SECTION * len(blobs)
    cmds_end = HEADER + sizeofcmds + added
    headers, cursor = b"", (cmds_end + 15) & ~15
    placements = []
    for name, blob in blobs:
        headers += struct.pack("<16s16sQQ8I", name, b"__TEXT", text_vmaddr + cursor, len(blob), cursor, 0, 0, 0, 0, 0, 0, 0)
        placements.append((cursor, blob))
        cursor = (cursor + len(blob) + 15) & ~15
    if cursor > first_section:
        sys.exit("error: not enough free space after the load commands")

    # New section headers go first in __TEXT (sections are listed by address),
    # so everything after that point in the load commands moves down.
    insert_at = text_cmd + SEGMENT
    tail = bytes(data[insert_at : HEADER + sizeofcmds])
    data[insert_at : insert_at + added + len(tail)] = headers + tail
    for where, blob in placements:
        data[where : where + len(blob)] = blob

    cmdsize, nsects = struct.unpack_from("<I", data, text_cmd + 4)[0], struct.unpack_from("<I", data, text_cmd + 64)[0]
    struct.pack_into("<I", data, text_cmd + 4, cmdsize + added)
    struct.pack_into("<I", data, text_cmd + 64, nsects + len(blobs))
    struct.pack_into("<I", data, 20, sizeofcmds + added)
    open(path, "wb").write(data)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
