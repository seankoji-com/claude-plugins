"""Discover once; reject an empty suite and retain unittest's enforcing result."""
from pathlib import Path
import sys
import unittest


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent / 'python'))
    count = suite.countTestCases()
    if not count:
        sys.exit('ERROR: no Python tests discovered')
    print(f'Discovered {count} Python tests', flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
