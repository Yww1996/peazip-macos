"""Run after swift test and package.sh; tests an isolated debug app, not /Applications."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess

repo = Path(__file__).resolve().parent.parent
work = repo / "build/service-launch-test"
if work.exists():
    shutil.rmtree(work)
work.mkdir(parents=True)
app = work / "ZunoLaunchProbe.app"
shutil.copytree(repo / "build/Zuno.app", app, symlinks=True)
executable = app / "Contents/MacOS/Zuno"
shutil.copy2(repo / ".build/debug/PeaZip27", executable)
info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info.pop("NSServices", None)
info.pop("CFBundleDocumentTypes", None)
info["CFBundleName"] = "ZunoLaunchProbe"
info["SUEnableAutomaticChecks"] = False

source = work / "内容.txt"
source.write_text("后台解压的内容校验", encoding="utf-8")
archive = work / "收球照片.zip"
subprocess.run([str(repo / "assets/engine/7z/7z"), "a", str(archive), str(source)],
               check=True, stdout=subprocess.DEVNULL)
for scenario in ["ui", "service", "warm"]:
    info["CFBundleIdentifier"] = f"com.yww.pea27.launch-probe.{scenario}"
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)],
                   check=True, capture_output=True)
    report = work / f"{scenario}.json"
    desktop = work / f"{scenario}-Desktop"
    desktop.mkdir()
    environment = dict(os.environ, PEAZIP_TEST_LAUNCH_KIND="service" if scenario == "service" else "ui",
                       PEAZIP_TEST_REPORT=str(report), PEAZIP_TEST_DESKTOP=str(desktop))
    if scenario != "ui":
        environment["PEAZIP_TEST_ARCHIVE"] = str(archive)
    result = subprocess.run([str(executable)], env=environment, capture_output=True, timeout=12)
    assert result.returncode == 0, f"GUI process exit={result.returncode}; " + result.stderr.decode(errors="replace")[-2000:]
    assert report.exists(), result.stderr.decode(errors="replace")[-2000:]
    data = json.loads(report.read_text())
    expected = 0 if scenario == "service" else 1
    assert data["maxVisibleWindows"] == expected, data
    assert data["backgroundOnly"] == (scenario == "service"), data
    if scenario != "ui":
        output = desktop / "收球照片/内容.txt"
        assert output.read_bytes() == source.read_bytes()
    print(f"PASS {scenario}: maximum visible windows={expected}", flush=True)
