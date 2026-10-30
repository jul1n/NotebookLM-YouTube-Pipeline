"""HTTP checks against a disposable project; no production server is started."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request


class DashboardServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('pwsh'):
            raise unittest.SkipTest('PowerShell 7 unavailable')
        scripts = Path(os.environ.get('PIPELINE_TEST_SCRIPTS', Path(__file__).parent))
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        (cls.root/'SCRIPTS').mkdir()
        (cls.root/'DATABASE').mkdir()
        (cls.root/'assets'/'packs').mkdir(parents=True)
        (cls.root/'Dashboard.html').write_text('<html>test dashboard</html>')
        (cls.root/'DATABASE'/'cookie.txt').write_text('synthetic secret')
        (cls.root/'assets'/'packs'/'test.txt').write_text('pack')
        shutil.copyfile(scripts/'Global-Paths.ps1', cls.root/'SCRIPTS'/'Global-Paths.ps1')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        source = (scripts/'Run-Dashboard-Server.ps1').read_text(encoding='utf-8-sig')
        source = source.replace('$Port = 8080', f'$Port = {port}')
        server = cls.root/'SCRIPTS'/'Run-Dashboard-Server.ps1'
        server.write_text(source, encoding='utf-8')
        cls.base = f'http://localhost:{port}'
        cls.process = subprocess.Popen(['pwsh','-NoProfile','-File',str(server)], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.base,timeout=1).close()
                return
            except (OSError, urllib.error.URLError):
                if cls.process.poll() is not None:
                    break
                time.sleep(.1)
        cls.process.kill()
        cls.process.wait()
        cls.temp.cleanup()
        raise RuntimeError('Disposable dashboard server did not start')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.temp.cleanup()

    def request(self, path, method='GET', headers=None):
        req = urllib.request.Request(self.base+path,method=method,headers=headers or {})
        try:
            with urllib.request.urlopen(req,timeout=5) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code,error.read()

    def test_dashboard_and_pack_accessible(self):
        self.assertEqual(self.request('/')[0],200)
        self.assertEqual(self.request('/assets/packs/test.txt'),(200,b'pack'))

    def test_database_and_scripts_not_served(self):
        for path in ('/DATABASE/cookie.txt','/SCRIPTS/Global-Paths.ps1','/assets/../DATABASE/cookie.txt'):
            self.assertEqual(self.request(path)[0],403,path)

    def test_purge_get_and_unmarked_post_rejected(self):
        self.assertEqual(self.request('/api/purge?file=x')[0],405)
        self.assertEqual(self.request('/api/purge?file=x',method='POST')[0],405)

    def test_cross_origin_purge_rejected(self):
        self.assertEqual(self.request('/api/purge?file=x',method='POST',headers={'X-Pipeline-Action':'purge','Origin':'https://example.com'})[0],405)

    def test_storage_read_never_starts_audit(self):
        self.assertEqual(self.request('/api/storage'),(200,b'{}'))


if __name__ == '__main__':
    unittest.main()
