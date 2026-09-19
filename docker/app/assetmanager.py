import os
import time
import shutil
import subprocess
from datetime import datetime
from typing import Dict, Any, Optional, Tuple


class AssetManager:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.custom_dir = os.path.join(data_dir, "assets")
        os.makedirs(self.custom_dir, exist_ok=True)
        self.builtin_dir = self._find_builtin_asset_dir()

    def _find_builtin_asset_dir(self) -> Optional[str]:
        for d in ["/usr/local/share/xray", "/usr/share/xray", "/usr/share/v2ray"]:
            if os.path.exists(os.path.join(d, "geosite.dat")) or os.path.exists(os.path.join(d, "geoip.dat")):
                return d
        return None

    def _file_info(self, path: str) -> Optional[Dict[str, Any]]:
        if not os.path.isfile(path):
            return None
        st = os.stat(path)
        dt = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        size_mb = round(st.st_size / (1024 * 1024), 2)
        return {
            "path": path,
            "size_bytes": st.st_size,
            "size_formatted": f"{size_mb} MB" if size_mb >= 1 else f"{round(st.st_size / 1024, 1)} KB",
            "modified": dt
        }

    def get_status(self, asset_source_setting: str = "custom") -> Dict[str, Any]:
        custom_geosite = os.path.join(self.custom_dir, "geosite.dat")
        custom_geoip = os.path.join(self.custom_dir, "geoip.dat")
        prev_geosite = os.path.join(self.custom_dir, "geosite.dat.previous")
        prev_geoip = os.path.join(self.custom_dir, "geoip.dat.previous")

        builtin_geosite = os.path.join(self.builtin_dir, "geosite.dat") if self.builtin_dir else None
        builtin_geoip = os.path.join(self.builtin_dir, "geoip.dat") if self.builtin_dir else None

        has_custom = os.path.isfile(custom_geosite) and os.path.isfile(custom_geoip)
        has_builtin = bool(self.builtin_dir and os.path.isfile(builtin_geosite) and os.path.isfile(builtin_geoip))
        has_prev = os.path.isfile(prev_geosite) or os.path.isfile(prev_geoip)

        active_source = "builtin"
        active_dir = self.builtin_dir

        if asset_source_setting == "custom":
            if has_custom:
                active_source = "custom"
                active_dir = self.custom_dir
            elif has_builtin:
                active_source = "builtin_fallback"
                active_dir = self.builtin_dir
        else:
            active_source = "builtin"

        active_geosite = os.path.join(active_dir, "geosite.dat") if active_dir else None
        active_geoip = os.path.join(active_dir, "geoip.dat") if active_dir else None

        return {
            "active_source": active_source,
            "active_dir": active_dir,
            "geosite": self._file_info(active_geosite) if active_geosite else None,
            "geoip": self._file_info(active_geoip) if active_geoip else None,
            "has_custom": has_custom,
            "custom_dir": self.custom_dir,
            "has_builtin": has_builtin,
            "builtin_dir": self.builtin_dir,
            "has_previous": has_prev
        }

    def activate_uploaded_asset(self, filename: str, temp_path: str) -> Tuple[bool, str]:
        filename = filename.lower()
        if filename not in ("geosite.dat", "geoip.dat"):
            return False, "File must be named geosite.dat or geoip.dat"

        if not os.path.isfile(temp_path) or os.path.getsize(temp_path) < 10240:
            return False, "Uploaded rule file is too small or corrupt"

        target = os.path.join(self.custom_dir, filename)
        prev = target + ".previous"

        # Replace using copyfile to support cross-device moves
        shutil.copyfile(temp_path, target)
        try:
            os.remove(temp_path)
        except Exception:
            pass
        os.chmod(target, 0o644)
        return True, f"Rule file {filename} updated successfully"

    def rollback(self) -> Tuple[bool, str]:
        restored = 0
        for name in ["geosite.dat", "geoip.dat"]:
            target = os.path.join(self.custom_dir, name)
            prev = target + ".previous"
            if os.path.isfile(prev):
                shutil.copyfile(prev, target)
                restored += 1

        if restored == 0:
            return False, "No previous rule files available to rollback"
        return True, f"Rolled back {restored} rule files"

    def download_loyalsoldier_rules(self, proxy: Optional[str] = None) -> Tuple[bool, str]:
        urls = {
            "geosite.dat": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
            "geoip.dat": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        }

        updated = []
        for name, url in urls.items():
            tmp = os.path.join(self.custom_dir, name + ".downloading")
            cmd = ["curl", "-sSL", "--retry", "3", "-o", tmp]
            if proxy:
                cmd.extend(["--proxy", proxy])
            cmd.append(url)

            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            if res.returncode == 0 and os.path.isfile(tmp) and os.path.getsize(tmp) > 50000:
                target = os.path.join(self.custom_dir, name)
                prev = target + ".previous"
                if os.path.isfile(target):
                    shutil.copyfile(target, prev)
                shutil.copyfile(tmp, target)
                try:
                    os.remove(tmp)
                except Exception:
                    pass
                os.chmod(target, 0o644)
                updated.append(name)
            else:
                if os.path.exists(tmp):
                    os.remove(tmp)
                return False, f"Failed to download {name} via {url}"

        return True, f"Successfully updated rules: {', '.join(updated)}"
