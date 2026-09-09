import Foundation

/// Real WebM files, small enough to read inline.
///
/// **Written by a real encoder, not built by hand.** A hand-assembled EBML tree
/// tests the parser against the same understanding that wrote it; these came out
/// of libvpx and ffmpeg's own muxer, so what they exercise is the format as
/// something else actually writes it — including the two shapes that differ from
/// Discord's own asset only in ways a parser has to survive.
///
/// Each is 128x64, three frames at twelve a second, with the same authored
/// content: red ramping across the width and **alpha ramping down the height**,
/// from fully transparent on the first row to fully opaque on the last. That
/// pattern is what makes an alpha channel that is missing, constant, inverted or
/// scaled visible as a failed assertion rather than as a picture somebody has to
/// look at.
///
/// **Sixty-four is a floor, not a taste.** VideoToolbox's VP9 decoder refuses to
/// open a session for anything smaller in either dimension — measured, and
/// documented on `VP9Decoder.init` — so a tidier 32x16 fixture tests the
/// demuxer and never reaches a decoder at all.
enum WebMFixtures {

    /// VP9 with alpha, muxed to a file — the shape Discord serves.
    static let vp9Alpha = decode(
        "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAQAEU2b"
            + "dLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHYTbuMU6uEElTDZ1OsggEpTbuMU6uE"
            + "HFO7a1OsggPq7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAVSalmsirXsYMPQkBNgI1MYXZmNjIuMTIuMTAyV0GNTGF2ZjYyLjEyLjEwMkSJ"
            + "iEBvQAAAAAAAFlSua8yuAQAAAAAAAEPXgQFzxYh0Bwi32Q22hpyBACK1nIN1bmSIgQCG"
            + "hVZfVlA5g4EBI+ODhAT3kNXglLCBgLqBQJqBAlPAgQFVsIRVuYEBElTDZ0CAc3OgY8CA"
            + "Z8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDJzc9pjwItjxYh0Bwi32Q22hmfIpUWj"
            + "h0VOQ09ERVJEh5hMYXZjNjIuMjguMTAyIGxpYnZweC12cDlnyKFFo4hEVVJBVElPTkSH"
            + "kzAwOjAwOjAwLjI1MDAwMDAwMAAfQ7Z1QjXngQCgQcmhQSKBAAAAgkmDQgAH8AP2ADgk"
            + "HBgAAAAgAABqff////bKAB65wuQF6xYGjVkOx6zj6O1keZVwBbtr8AAAAmv68CLf4N97"
            + "NMXZbOGAR/83DcV50/z1WX3qf/ptImn5/5D109ZDWnLYyEy4/WBn8DP4GfwM/gZ/AyoA"
            + "AAAY9KP+8EvoNFqkZ7NMWJYf5D109vf98GN1T//fBjdU//3wY3U1OBgfeidtE7ckOu3u"
            + "Y0TMn0ls5eB3MaJmT6NAAAABvMw73NKP+X3g2zZD4GJ/fBjdU//3wY3VP/98GN1T//su"
            + "Eh/EBxCgxsdzGiZk+ktnLwSP3MfuY/cx+mAAAAFzSj/vBL6DRapGezTFiWH++wOr9If9"
            + "9gdX6Q/77A6v0h/32B1fkCE94HWhQKCmQJ3ugQGlQJeCSYNCAAfwA/YAOCQcGAAAACAA"
            + "AGp1////ueQpczfrtn/03hs3frtn/03hs3frtn/03hs3frtn/03hs3frtn/3p8FY2qzv"
            + "/TeGzd+u2f/TeGzd+ugCC/H/pvDZu/XbP/pvDZu/XbP/stKFJ/gQr/pvDZu/XbP/pvDZ"
            + "u/XbP/pvDZu/XbP/pvDZu/XbP/stKFJ/3sAUHsAAoLGhk4EAUwCGAECSnABAAAACAABY"
            + "1AB1oZamlO6BAaWPhgBAkpwAQAAAAgAAWNQA+4GtoLGhk4EApwCGAECSnABAAAACAABY"
            + "1AB1oZamlO6BAaWPhgBAkpwAQAAAAgAAWNQA+4GsHFO7a5G7j7OBALeK94EB8YIBr/CB"
            + "Aw=="
    )

    /// The same content muxed to a **pipe**, so its segment carries EBML's
    /// "size not yet known" instead of a length, and ffmpeg reserves room for
    /// the seek head it cannot go back and write with a hundred bytes of
    /// `Void`. A parser that trusts the size it is given, or that stops at the
    /// first element it does not recognise, reads no frames at all out of this.
    static let vp9UnknownSize = decode(
        "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwH/////////EU2b"
            + "dKtNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHNTbuMU6uEElTDZ1OsggEe7AEAAAAA"
            + "AABoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAVSalmpyrXsYMPQkBNgI1MYXZmNjIuMTIuMTAyV0GNTGF2ZjYyLjEyLjEwMhZU"
            + "rmvMrgEAAAAAAABD14EBc8WIOT5JtibczNCcgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPj"
            + "g4QE95DV4JSwgYC6gUCagQJTwIEBVbCEVbmBARJUw2fcc3OgY8CAZ8iaRaOHRU5DT0RF"
            + "UkSHjUxhdmY2Mi4xMi4xMDJzc7ZjwItjxYg5Pkm2JtzM0GfIpUWjh0VOQ09ERVJEh5hM"
            + "YXZjNjIuMjguMTAyIGxpYnZweC12cDkfQ7Z1QjXngQCgQcmhQSKBAAAAgkmDQgAH8AP2"
            + "ADgkHBgAAAAgAABqff////bKAB65wuQF6xYGjVkOx6zj6O1keZVwBbtr8AAAAmv68CLf"
            + "4N97NMXZbOGAR/83DcV50/z1WX3qf/ptImn5/5D109ZDWnLYyEy4/WBn8DP4GfwM/gZ/"
            + "AyoAAAAY9KP+8EvoNFqkZ7NMWJYf5D109vf98GN1T//fBjdU//3wY3U1OBgfeidtE7ck"
            + "Ou3uY0TMn0ls5eB3MaJmT6NAAAABvMw73NKP+X3g2zZD4GJ/fBjdU//3wY3VP/98GN1T"
            + "//suEh/EBxCgxsdzGiZk+ktnLwSP3MfuY/cx+mAAAAFzSj/vBL6DRapGezTFiWH++wOr"
            + "9If99gdX6Q/77A6v0h/32B1fkCE94HWhQKCmQJ3ugQGlQJeCSYNCAAfwA/YAOCQcGAAA"
            + "ACAAAGp1////ueQpczfrtn/03hs3frtn/03hs3frtn/03hs3frtn/03hs3frtn/3p8FY"
            + "2qzv/TeGzd+u2f/TeGzd+ugCC/H/pvDZu/XbP/pvDZu/XbP/stKFJ/gQr/pvDZu/XbP/"
            + "pvDZu/XbP/pvDZu/XbP/pvDZu/XbP/stKFJ/3sAUHsAAoLGhk4EAUwCGAECSnABAAAAC"
            + "AABY1AB1oZamlO6BAaWPhgBAkpwAQAAAAgAAWNQA+4GtoLGhk4EApwCGAECSnABAAAAC"
            + "AABY1AB1oZamlO6BAaWPhgBAkpwAQAAAAgAAWNQA+4Gs"
    )

    /// One frame. A still, and the filmstrip must say so rather than build a
    /// loop of one picture.
    static let vp9SingleFrame = decode(
        "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAOaEU2b"
            + "dLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHYTbuMU6uEElTDZ1OsggEpTbuMU6uE"
            + "HFO7a1OsggOE7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAVSalmsirXsYMPQkBNgI1MYXZmNjIuMTIuMTAyV0GNTGF2ZjYyLjEyLjEwMkSJ"
            + "iEBUwAAAAAAAFlSua8yuAQAAAAAAAEPXgQFzxYjZBWQztdAeWJyBACK1nIN1bmSIgQCG"
            + "hVZfVlA5g4EBI+ODhAT3kNXglLCBgLqBQJqBAlPAgQFVsIRVuYEBElTDZ0CAc3OgY8CA"
            + "Z8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDJzc9pjwItjxYjZBWQztdAeWGfIpUWj"
            + "h0VOQ09ERVJEh5hMYXZjNjIuMjguMTAyIGxpYnZweC12cDlnyKFFo4hEVVJBVElPTkSH"
            + "kzAwOjAwOjAwLjA4MzAwMDAwMAAfQ7Z1Qc/ngQCgQcmhQSKBAAAAgkmDQgAH8AP2ADgk"
            + "HBgAAAAgAABqff////bKAB65wuQF6xYGjVkOx6zj6O1keZVwBbtr8AAAAmv68CLf4N97"
            + "NMXZbOGAR/83DcV50/z1WX3qf/ptImn5/5D109ZDWnLYyEy4/WBn8DP4GfwM/gZ/AyoA"
            + "AAAY9KP+8EvoNFqkZ7NMWJYf5D109vf98GN1T//fBjdU//3wY3U1OBgfeidtE7ckOu3u"
            + "Y0TMn0ls5eB3MaJmT6NAAAABvMw73NKP+X3g2zZD4GJ/fBjdU//3wY3VP/98GN1T//su"
            + "Eh/EBxCgxsdzGiZk+ktnLwSP3MfuY/cx+mAAAAFzSj/vBL6DRapGezTFiWH++wOr9If9"
            + "9gdX6Q/77A6v0h/32B1fkCE94HWhQKCmQJ3ugQGlQJeCSYNCAAfwA/YAOCQcGAAAACAA"
            + "AGp1////ueQpczfrtn/03hs3frtn/03hs3frtn/03hs3frtn/03hs3frtn/3p8FY2qzv"
            + "/TeGzd+u2f/TeGzd+ugCC/H/pvDZu/XbP/pvDZu/XbP/stKFJ/gQr/pvDZu/XbP/pvDZ"
            + "u/XbP/pvDZu/XbP/pvDZu/XbP/stKFJ/3sAUHsAAHFO7a5G7j7OBALeK94EB8YIBr/CB"
            + "Aw=="
    )

    /// VP8, no alpha. The demuxer reads it; the filmstrip refuses it.
    static let vp8 = decode(
        "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAANcEU2b"
            + "dLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHYTbuMU6uEElTDZ1OsggElTbuMU6uE"
            + "HFO7a1OsggNG7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAVSalmsirXsYMPQkBNgI1MYXZmNjIuMTIuMTAyV0GNTGF2ZjYyLjEyLjEwMkSJ"
            + "iEBvQAAAAAAAFlSua8iuAQAAAAAAAD/XgQFzxYiR1ZU6riTZRpyBACK1nIN1bmSIgQCG"
            + "hVZfVlA4g4EBI+ODhAT3kNXgkLCBgLqBQJqBAlWwhFW5gQESVMNn/HNzoGPAgGfImkWj"
            + "h0VOQ09ERVJEh41MYXZmNjIuMTIuMTAyc3PWY8CLY8WIkdWVOq4k2UZnyKFFo4dFTkNP"
            + "REVSRIeUTGF2YzYyLjI4LjEwMiBsaWJ2cHhnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAw"
            + "LjI1MDAwMDAwMAAfQ7Z1QZrngQCjQWKBAACAkAsAnQEqgABAAABHCIWFiIWEiAICDsKa"
            + "vkVS489/Af1N9gmq/oD+TeBgJ96C/ALX+faCH4dAV/AZSm3tVM5eSCKvasAVWdR/yz0n"
            + "+ODObGbI6dwW/Yv+UrW1sWWWWWWWWWWWWWNg/v//FJcsj4wqbPPFz/43+lYxKJYA9hw0"
            + "hzmrdwBJbmu2euWGnf4fj9P8UMESxkM78w12vWtQqOgk/TvzCv4NifzuClOJCcRliuoG"
            + "6Cz4cNIdZdu/uf3+KGCJYyGd+Yce4wAAAAAAAAvuAAAAAAAAAFeKQAAAAAAAAOVAAAAA"
            + "AAAACTkAAAAAAAAK8UgAAAAAAAAWbAAAAAAAADAgAAAAAAAABgQAAAAAAAAArxSAAAAA"
            + "AAAByoAAAAAAAAASUAAAAAAAAAF8wAAAAAAABXikAAAAAAAACzYAAAAAAAASUAAAAAAA"
            + "AAJKAAAAAAAAAFeKQAAAAAAAAACjl4EAUwDxAQAFEKwAGAAYWC/0AAiBnwAAo5eBAKcA"
            + "8QEABRCsABgAGFgv9AAIgZ8AABxTu2uRu4+zgQC3iveBAfGCAabwgQM="
    )

    static let width = 128
    static let height = 64
    static let frameCount = 3

    private static func decode(_ base64: String) -> Data {
        Data(base64Encoded: base64) ?? Data()
    }
}
