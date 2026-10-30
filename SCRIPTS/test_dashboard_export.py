from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import dashboard_export as exporter
import pipeline_core as core


class DashboardExportTest(unittest.TestCase):
    def test_template_parser_rejects_non_select(self):
        with self.assertRaises(ValueError):exporter.query_template('$q = "DELETE FROM videos"','q')
        self.assertEqual(exporter.query_template('$q = @"\nSELECT 1;\n"@','q'),'SELECT 1;')

    def test_python_generation_never_executes_powershell_or_changes_videos(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'DATABASE').mkdir()
            dbpath=root/'DATABASE'/'PIPELINE_V15.db'
            with core.closing_database(sqlite3.connect(dbpath)) as db:
                db.executescript("CREATE TABLE channels(id INTEGER); CREATE TABLE videos(status TEXT,transcript TEXT); INSERT INTO channels VALUES(1); INSERT INTO videos VALUES('PENDING','Bonjour');")
            script=root/'template.ps1'
            script.write_text('''$statsSql = @"
SELECT 1 AS totalVids,0 AS totalHours,1 AS totalWords;
"@
$searchSql = "SELECT transcript FROM videos;"
$healthSql = @"
SELECT 'Test' AS Chaine;
"@
$recoverySql = "SELECT status FROM videos;"
''',encoding='utf-8')
            with patch('subprocess.run',side_effect=AssertionError('script executed')):
                result=exporter.export_dashboard(core.Runtime(root),script)
            self.assertEqual(result['engine'],'python')
            self.assertIn('GLOBAL_STATS',(root/'assets'/'stats.js').read_text())
            self.assertIn('GLOBAL_RECOVERY',(root/'assets'/'health.js').read_text())
            with core.closing_database(core.connect(dbpath,True)) as db:self.assertEqual(db.execute('SELECT transcript FROM videos').fetchone()[0],'Bonjour')


if __name__=='__main__':unittest.main()
