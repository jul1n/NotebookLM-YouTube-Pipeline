"""Compatibility entry point: transcribe audio directly, one item by default."""
import sys
from pipeline_core import main
if __name__ == '__main__':
    sys.argv.insert(1, 'transcribe')
    main()
