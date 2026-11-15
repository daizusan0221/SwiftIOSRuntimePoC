import plistlib
import stat
import struct
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def validate_executable(path):
    data = path.read_bytes()
    magic, cpu, _, filetype, command_count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, filetype) != (0xFEEDFACF, 0x0100000C, 2):
        raise ValueError("Expected a thin arm64 Mach-O executable")
    command_end = 32 + command_bytes
    if command_end > len(data):
        raise ValueError("Truncated Mach-O load commands")
    offset = 32
    ios = False
    for _ in range(command_count):
        command, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or offset + size > command_end:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x1D:
            raise ValueError("Unexpected LC_CODE_SIGNATURE")
        if command == 0x32 and size >= 24:
            ios |= struct.unpack_from("<I", data, offset + 8)[0] == 2
        offset += size
    if offset != command_end or not ios:
        raise ValueError("Expected LC_BUILD_VERSION for an iOS device")


def package(app, output):
    plist_path = app / "Info.plist"
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    executable_name = info["CFBundleExecutable"]
    if executable_name != app.stem or info["CFBundlePackageType"] != "APPL":
        raise ValueError("Bundle name, executable and package type do not match")
    executable = app / executable_name
    validate_executable(executable)
    print(f"Bundle validated: {info['CFBundleIdentifier']} / iOS {info['MinimumOSVersion']}")

    prefix = f"Payload/{app.name}"
    with ZipFile(output, "x") as archive:
        for path, mode in ((plist_path, 0o644), (executable, 0o755)):
            entry = ZipInfo(f"{prefix}/{path.name}")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(entry, path.read_bytes(), compress_type=ZIP_DEFLATED)
    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA ZIP CRC check failed")
        if archive.getinfo(f"{prefix}/{executable.name}").external_attr >> 16 & 0o111 == 0:
            raise ValueError("IPA executable permissions are missing")
    print(f"Unsigned bundle archive validated: {output}")


if __name__ == "__main__":
    package(Path(sys.argv[1]), Path(sys.argv[2]))
