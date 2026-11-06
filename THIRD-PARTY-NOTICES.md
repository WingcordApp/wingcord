# Third-party notices

## Noodle

Parts of Wingcord's wallpaper support are adapted from Noodle
(https://github.com/pdparchitect/noodle), which is distributed under the Apache
License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).

Adapted, with changes:

- `Sources/Wingcord/Wallpaper/WallpaperMedia.swift` — `SystemWallpaper`'s discovery
  of macOS's downloaded wallpapers and aerial videos.
- `Sources/Wingcord/Wallpaper/WallpaperLayer.swift` — the looping, muted video
  wallpaper that pauses while the window is out of sight, and the preset scenes'
  gradient-and-light recipe.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
those files except in compliance with the License. Unless required by applicable
law or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing
permissions and limitations under the License.

## highlight.js

Code blocks and text-file previews are highlighted by highlight.js 11.11.1
(https://highlightjs.org), bundled unmodified — the official
`@highlightjs/cdn-assets` build, core and every language — at
`Sources/Wingcord/Resources/Highlight/highlight.js`, with its licence beside it.

BSD 3-Clause License

Copyright (c) 2006, Ivan Sagalaev.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## ansi-sequence-parser

`Packages/WingcordCore/Sources/WingcordCore/ANSIEscapes.swift` is a Swift port
of ansi-sequence-parser (https://github.com/blake-mealey/ansi-sequence-parser),
by Blake Mealey — the parser Discord draws `ansi` code blocks with. Its package
declares the MIT License; the notice below is that licence.

MIT License

Copyright (c) Blake Mealey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## mediaremote-adapter

The Now Playing presence reads what macOS says is playing through
mediaremote-adapter (https://github.com/ungive/mediaremote-adapter, commit
`0e82bf1`), vendored with its licence at `Packaging/MediaRemoteAdapter/` — the
Perl loader and the framework sources, built into
`Contents/Frameworks/MediaRemoteAdapter.framework`. Unmodified except that
`src/adapter/test.m` (its self-test command) is left out.

BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
## MetalForge

The sign-in screen's ember wallpaper and its particle logo are adapted from
MetalForge shaders (the "Wallpaper" gradient and "metallogo"), used under the
project owner's MetalForge subscription:

- `Sources/Wingcord/Welcome/Shaders/SignInBackdrop.metal` — `wallpaperGradient`'s
  arithmetic, unchanged, split into a half-size field pass and a full-size
  vignette and grain pass; `metallogoVertex` and `metallogoFragment`, with an
  offset, an opacity and an exit added.
- `Sources/Wingcord/Welcome/EmberRenderer.swift` and `ParticleLockup.swift` —
  the renderer and the mask sampling, ported from iOS to macOS and reshaped to
  gather into Wingcord's wings and wordmark.
