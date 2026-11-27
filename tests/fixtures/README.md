# Test archives

The RAR fixture is libarchive's own test data, `test_read_format_rar.rar` from
[libarchive](https://github.com/libarchive/libarchive) 3.8.11, uuencoded the way
libarchive stores it. It comes under libarchive's BSD 2-Clause licence, whose
text is in [third_party/libarchive/LICENSE](../../third_party/libarchive/LICENSE)
and in the app's `Notices` folder. The tests decode it and read it, so a real
RAR4 archive is exercised rather than only the ones they build.

The 7z fixtures are not stored here: the tests write them with libarchive's own
7z encoder, and the RAR4 and RAR5 archives they build themselves hold no game
data either.
