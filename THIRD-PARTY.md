# Third-party components

`dev.cajeta.codec` is Apache-2.0. It vendors one third-party component for its
optional native compression backend:

## zlib

- **Version:** 1.3.1 (tag `v1.3.1`), from https://github.com/madler/zlib
- **Location:** `native/zlib/` — unmodified upstream C sources, buffer-API
  subset (the `gz*` file-I/O TUs are omitted; `gzguts.h` kept for `zutil.c`).
  See `native/zlib/VENDORED.txt`.
- **Used by:** the native backend (`src/main/.../compress/NativeZlib.cajeta` via
  the shim `native/cajeta_zlib_shim.c`), built static by `native/build.sh` (host)
  and `native/cross-build.sh` (all six target triples).
- **License:** the zlib License (permissive; static linking permitted with the
  notice retained). Full text in `native/zlib/LICENSE`:

> Copyright (C) 1995-2024 Jean-loup Gailly and Mark Adler
>
> This software is provided 'as-is', without any express or implied warranty.
> In no event will the authors be held liable for any damages arising from the
> use of this software.
>
> Permission is granted to anyone to use this software for any purpose,
> including commercial applications, and to alter it and redistribute it
> freely, subject to the following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not claim
>    that you wrote the original software. If you use this software in a product,
>    an acknowledgment in the product documentation would be appreciated but is
>    not required.
> 2. Altered source versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
> 3. This notice may not be removed or altered from any source distribution.
>
> Jean-loup Gailly        Mark Adler
> jloup@gzip.org          madler@alumni.caltech.edu

The vendored sources are unmodified. `native/cajeta_zlib_shim.c` is our own
code (Apache-2.0) that calls into zlib; it is not a modified zlib source.

Note: `src/main/.../compress/DynDeflate.cajeta` is a separate, independent cajeta
**port** of zlib's dynamic-Huffman and lazy-matching algorithms (not a use of
this vendored library); it carries the zlib notice in its own file header.
