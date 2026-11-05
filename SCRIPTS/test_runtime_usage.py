import tempfile
from pathlib import Path
import unittest
import pipeline_core as core

class RuntimeUsageTest(unittest.TestCase):
    def test_exact_nested_sizes_and_missing_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);runtime=core.Runtime(root);runtime.local_root=root/'local'
            self.assertEqual(runtime.usage(),0)
            (runtime.local_root/'nested'/'empty').mkdir(parents=True)
            (runtime.local_root/'one').write_bytes(b'a'*31)
            (runtime.local_root/'nested'/'texte-é.txt').write_bytes(b'b'*137)
            expected=sum(p.stat().st_size for p in runtime.local_root.rglob('*') if p.is_file())
            self.assertEqual(runtime.usage(),168);self.assertEqual(runtime.usage(),expected)
            runtime.budget=167
            with self.assertRaisesRegex(RuntimeError,'Budget local'):runtime.check_space()

if __name__=='__main__':unittest.main()
