import os
import re
import shutil
import struct
import platform
import subprocess
import tempfile
from typing import Dict, Any, Optional, Tuple

ELF_MACHINES = {
    3: "i386",
    40: "arm",
    62: "x86_64",
    183: "aarch64"
}

ARCH_MAP = {
    "x86_64": "64",
    "amd64": "64",
    "aarch64": "arm64-v8a",
    "arm64": "arm64-v8a",
    "armv7l": "arm32-v7a",
    "arm": "arm32-v7a"
}


class CoreManager:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.bin_dir = os.path.join(data_dir, "bin")
        os.makedirs(self.bin_dir, exist_ok=True)
        self.custom_xray = os.path.join(self.bin_dir, "xray")
        self.prev_xray = os.path.join(self.bin_dir, "xray.previous")
        self.system_xray = self._find_system_xray()

    def _find_system_xray(self) -> Optional[str]:
        for p in ["/usr/local/bin/xray", "/usr/bin/xray"]:
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
        return None

    def get_system_arch(self) -> str:
        machine = platform.machine().lower()
        if machine in ("x86_64", "amd64"):
            return "x86_64"
        if machine in ("aarch64", "arm64", "armv8l"):
            return "aarch64"
        return machine

    def parse_xray_version(self, file_path: str) -> Optional[str]:
        if not (os.path.isfile(file_path) and os.access(file_path, os.X_OK)):
            return None
        try:
            res = subprocess.run([file_path, "version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
            out = res.stdout or res.stderr
            match = re.search(r"Xray\s+([0-9][0-9a-zA-Z\.\-]*)", out, re.IGNORECASE)
            if match:
                return match.group(1)
        except Exception:
            pass
        return None

    def check_elf_architecture(self, file_path: str) -> Tuple[bool, str]:
        try:
            with open(file_path, "rb") as f:
                header = f.read(64)
            if len(header) < 20 or header[:4] != b"\x7fELF":
                return False, "Not a valid Linux ELF executable"

            ei_data = header[5]
            if ei_data == 1:
                e_machine = struct.unpack("<H", header[18:20])[0]
            else:
                e_machine = struct.unpack(">H", header[18:20])[0]

            arch = ELF_MACHINES.get(e_machine, f"unknown({e_machine})")
            sys_arch = self.get_system_arch()

            if arch != sys_arch and not (arch == "i386" and sys_arch == "x86_64"):
                return False, f"Architecture mismatch: binary is {arch}, but system is {sys_arch}"

            return True, arch
        except Exception as e:
            return False, f"Failed to inspect ELF header: {e}"

    def get_status(self, core_source_setting: str = "custom") -> Dict[str, Any]:
        has_custom = os.path.isfile(self.custom_xray) and os.access(self.custom_xray, os.X_OK)
        has_prev = os.path.isfile(self.prev_xray) and os.access(self.prev_xray, os.X_OK)

        custom_ver = self.parse_xray_version(self.custom_xray) if has_custom else None
        builtin_ver = self.parse_xray_version(self.system_xray) if self.system_xray else None
        prev_ver = self.parse_xray_version(self.prev_xray) if has_prev else None

        active_source = "builtin"
        active_bin = self.system_xray
        active_version = builtin_ver

        if core_source_setting == "custom":
            if has_custom:
                active_source = "custom"
                active_bin = self.custom_xray
                active_version = custom_ver
            else:
                active_source = "builtin_fallback"
        else:
            active_source = "builtin"

        custom_size = os.path.getsize(self.custom_xray) if has_custom else 0
        builtin_size = os.path.getsize(self.system_xray) if self.system_xray else 0

        return {
            "active_source": active_source,
            "active_binary": active_bin,
            "active_version": active_version,
            "system_arch": self.get_system_arch(),
            "has_custom": has_custom,
            "custom_version": custom_ver,
            "custom_size": custom_size,
            "has_builtin": bool(self.system_xray),
            "builtin_version": builtin_ver,
            "builtin_size": builtin_size,
            "has_previous": has_prev,
            "previous_version": prev_ver
        }

    def activate_uploaded_file(self, temp_path: str) -> Tuple[bool, str]:
        os.chmod(temp_path, 0o755)

        # 1. ELF architecture check
        ok, arch_info = self.check_elf_architecture(temp_path)
        if not ok:
            return False, arch_info

        # 2. Xray executable check
        version = self.parse_xray_version(temp_path)
        if not version:
            return False, "File is not an operational Xray-core binary or failed to run"

        # 3. Backup current custom
        if os.path.isfile(self.custom_xray):
            prev_tmp = self.prev_xray + ".tmp"
            shutil.copyfile(self.custom_xray, prev_tmp)
            os.replace(prev_tmp, self.prev_xray)

        # 4. Copy to staging file in destination directory (handles cross-device),
        # then atomically replace over destination (avoids ETXTBSY on running binary)
        staging_file = self.custom_xray + ".new"
        shutil.copyfile(temp_path, staging_file)
        try:
            os.remove(temp_path)
        except Exception:
            pass
        os.chmod(staging_file, 0o755)
        os.replace(staging_file, self.custom_xray)
        return True, f"Xray-core v{version} ({arch_info}) activated successfully"

    def rollback(self) -> Tuple[bool, str]:
        if not os.path.isfile(self.prev_xray):
            return False, "No previous Xray-core binary available to rollback"
        prev_ver = self.parse_xray_version(self.prev_xray) or "previous"
        staging_file = self.custom_xray + ".rollback"
        shutil.copyfile(self.prev_xray, staging_file)
        os.chmod(staging_file, 0o755)
        os.replace(staging_file, self.custom_xray)
        return True, f"Rolled back to Xray-core v{prev_ver}"

    def download_github_release(self, version: str, proxy: Optional[str] = None) -> Tuple[bool, str]:
        if not version.startswith("v"):
            version = "v" + version

        sys_arch = self.get_system_arch()
        arch_code = ARCH_MAP.get(sys_arch, "64")
        url = f"https://github.com/XTLS/Xray-core/releases/download/{version}/Xray-linux-{arch_code}.zip"

        temp_dir = tempfile.mkdtemp(prefix="xray_dl_")
        zip_path = os.path.join(temp_dir, "xray.zip")
        try:
            cmd = ["curl", "-sSL", "--retry", "3", "-o", zip_path]
            if proxy:
                cmd.extend(["--proxy", proxy])
            cmd.append(url)

            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            if res.returncode != 0 or not os.path.exists(zip_path) or os.path.getsize(zip_path) < 1000:
                return False, f"Failed to download Xray-core from GitHub release: {res.stderr.decode() or 'Connection failed'}"

            # Unzip
            unzip_dir = os.path.join(temp_dir, "extracted")
            os.makedirs(unzip_dir, exist_ok=True)
            res_unzip = subprocess.run(["unzip", "-q", zip_path, "-d", unzip_dir], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if res_unzip.returncode != 0:
                return False, "Failed to extract downloaded zip archive"

            bin_file = os.path.join(unzip_dir, "xray")
            if not os.path.exists(bin_file):
                return False, "xray binary not found inside downloaded package"

            return self.activate_uploaded_file(bin_file)
        except Exception as e:
            return False, f"Download error: {e}"
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)
