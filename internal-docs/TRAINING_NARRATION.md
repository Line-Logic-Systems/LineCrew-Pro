# LineCrew Pro training narration

The narration workflow converts the approved per-slide scripts in
`training/narration/slides.json` into one MP3 file per slide through ElevenLabs.

## Security

- `ELEVENLABS_API_KEY` must exist only as a GitHub Actions secret.
- Never place the key in `index.html`, repository files, workflow logs, issues,
  pull requests, or presentation notes.
- The ElevenLabs key should allow Text to Speech and read-only Voices access
  only, with a credit limit.

## Generate audio

1. In ElevenLabs, preview voices and note the narrator name. The default is
   **Roger**; short names also match labeled voices such as
   **Roger - Laid-Back, Casual, Resonant**.
2. Open **Actions → Generate training narration → Run workflow**.
3. Keep **Roger** or type another ElevenLabs voice name, then run the workflow.
4. Download the `linecrew-pro-training-narration` artifact after completion.

The artifact contains `slide-01.mp3` through `slide-33.mp3` plus the script
manifest used to produce them.

## Updating narration

Edit only the matching `script` value in `training/narration/slides.json`, then
rerun the workflow. The workflow does not modify application data or deploy the
LineCrew Pro site.
