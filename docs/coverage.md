# Python coverage

The report includes first-party Python throughout the repository, including plugin scripts and the build generator. `dist/` is omitted because it contains generated copies of those sources; test files and local virtual environments are also omitted. No vendored runtime directory is excluded.

CI keeps the existing test commands enforcing, then repeats the Python suite under pinned Coverage.py 7.16.1 as an advisory reporting step. Branch coverage and subprocess measurement are enabled. Unimported namespace-package files are included. Coverage is retained as a Cobertura XML artifact; publishing and new thresholds are not enabled yet. Shell and JavaScript execution is outside this Python report.

Local reproduction after installing test dependencies and Coverage.py:

```sh
coverage run -m unittest discover -s tests/python
coverage combine
coverage xml
```

A missing report is a reporting failure, not evidence of complete coverage. Review measured file paths and baseline on CI before enforcing any threshold.
