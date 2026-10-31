import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from preserve_git_history import preserve


class HistoryTest(unittest.TestCase):
    def test_code_and_old_captions_preserved_without_video(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'repo';root.mkdir()
            def git(*args):return subprocess.run(['git','-C',str(root),*args],capture_output=True,check=True).stdout.decode().strip()
            git('init');git('config','user.email','test@example.invalid');git('config','user.name','Test')
            (root/'code.py').write_text('old code',encoding='utf8')
            source_name='source [abcdefghijk].vtt'
            (root/source_name).write_text('old captions',encoding='utf8')
            (root/'video.webm').write_bytes(b'fake movie data')
            git('add','.');git('commit','-m','original')
            source_oid=git('rev-parse','HEAD:'+source_name);video_oid=git('rev-parse','HEAD:video.webm')
            (root/source_name).unlink();(root/'code.py').write_text('new code',encoding='utf8')
            git('add','-u');git('commit','-m','new')
            preserve(root)
            proof=json.loads((root/'DATABASE/history_safeguards/VERIFIED.json').read_text(encoding='utf8'))
            self.assertTrue(proof['verified'])
            bare=root/'DATABASE/history_safeguards/nonmedia-history.git'
            blobs=subprocess.run(['git','-C',str(bare),'rev-list','--objects','--all'],capture_output=True,check=True).stdout.decode()
            self.assertIn(source_oid,blobs);self.assertNotIn(video_oid,blobs)
            (root/'code.py').write_text('latest code',encoding='utf8');git('add','-u');git('commit','-m','latest')
            latest=git('rev-parse','HEAD:code.py');preserve(root)
            blobs=subprocess.run(['git','-C',str(bare),'rev-list','--objects','--all'],capture_output=True,check=True).stdout.decode()
            self.assertIn(latest,blobs);self.assertIn(source_oid,blobs)


if __name__=='__main__':unittest.main()
