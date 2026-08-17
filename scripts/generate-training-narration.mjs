import fs from "node:fs/promises";
import path from "node:path";

const key = process.env.ELEVENLABS_API_KEY;
const requestedVoiceName = (process.env.ELEVENLABS_VOICE_NAME || "Roger").trim();
const manifestPath = process.env.NARRATION_MANIFEST || "training/narration/slides.json";
const outputDir = process.env.NARRATION_OUTPUT_DIR || "training/narration/output";

if (!key) throw new Error("ELEVENLABS_API_KEY is required.");

const voicesResponse = await fetch("https://api.elevenlabs.io/v1/voices", {
  headers: { "xi-api-key": key },
});
if (!voicesResponse.ok) {
  throw new Error(`Unable to load ElevenLabs voices (${voicesResponse.status}): ${await voicesResponse.text()}`);
}
const voices = (await voicesResponse.json()).voices || [];
const selectedVoice = voices.find(
  (voice) => String(voice.name || "").toLowerCase() === requestedVoiceName.toLowerCase()
);
if (!selectedVoice) {
  const available = voices.map((voice) => voice.name).filter(Boolean).sort().join(", ");
  throw new Error(`Voice \"${requestedVoiceName}\" was not found. Available voices: ${available}`);
}
const voiceId = selectedVoice.voice_id;
process.stdout.write(`Using ElevenLabs voice: ${selectedVoice.name}\n`);

const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
await fs.mkdir(outputDir, { recursive: true });

for (const item of manifest.slides) {
  const filename = `slide-${String(item.slide).padStart(2, "0")}.mp3`;
  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=mp3_44100_128`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "xi-api-key": key,
      },
      body: JSON.stringify({
        text: item.script,
        model_id: manifest.model_id || "eleven_multilingual_v2",
        voice_settings: {
          stability: 0.58,
          similarity_boost: 0.78,
          style: 0.18,
          use_speaker_boost: true
        }
      })
    }
  );

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Slide ${item.slide} narration failed (${response.status}): ${detail}`);
  }

  await fs.writeFile(path.join(outputDir, filename), Buffer.from(await response.arrayBuffer()));
  process.stdout.write(`Generated ${filename}: ${item.title}\n`);
}

await fs.copyFile(manifestPath, path.join(outputDir, "slides.json"));
process.stdout.write(`Generated ${manifest.slides.length} narration files in ${outputDir}\n`);
