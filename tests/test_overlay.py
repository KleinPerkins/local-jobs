"""Exercise the real installer/handler in isolated fixtures; never install host jobs."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
class OverlayTests(unittest.TestCase):
    def test_real_installer_and_handler_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            env=dict(os.environ,TMPDIR=temp)
            result=subprocess.run(['bash','bin/test-local-overlay.sh'],cwd=ROOT,env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('local overlay test passed',result.stdout)
            self.assertEqual(list(Path(temp).iterdir()),[])
    def test_all_shell_sources_parse(self):
        paths=subprocess.check_output(['git','ls-files','*.sh'],cwd=ROOT,text=True).splitlines()
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path):subprocess.run(['bash','-n',path],cwd=ROOT,check=True)
if __name__=='__main__':unittest.main()
