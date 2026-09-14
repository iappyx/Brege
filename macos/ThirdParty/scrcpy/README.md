# scrcpy server (third party)

`scrcpy-server` is the unmodified server from [scrcpy](https://github.com/Genymobile/scrcpy)
v4.1 (Apache License 2.0, see `LICENSE`), used for the phone screen on the Mac.
Brêge pushes it to the phone over wireless debugging and speaks its protocol directly.

- Source: https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-server-v4.1
- SHA-256: `deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae`

The client and server versions must match exactly: when updating, change `ScreenSession.serverVersion`
and check the protocol notes in scrcpy's `doc/develop.md`.
