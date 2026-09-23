from gptloop_example import __version__


def test_version_is_set():
    assert __version__


def test_arithmetic_still_works():
    # A trivially true test so `action: test` has something real to run.
    assert 2 + 2 == 4
