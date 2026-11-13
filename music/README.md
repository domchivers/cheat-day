# Music for posts

30-second clips people can add to a post in Cheat Days. Every track was released under CC0 1.0 Universal (a public domain dedication): most are from FreePD.com, which released all its music that way and closed in 2025 (fetched from the Internet Archive's copy, archive.org/details/freepd); the lofi is HoliznaCC0's, from freemusicarchive.org; the metal, punk and some lofi are from OpenGameArt.org pages that list CC0 as their only licence. `SOURCES.json` records each clip's source address, the page it was on, its licence, where in the track the clip starts and the checksum of the file it was cut from. `music.json` is the list the app shows.

Rebuild with `python -I design/music_fetch.py`, `python -I design/music_fetch_more.py`, then `python -I design/music_clips.py`.
