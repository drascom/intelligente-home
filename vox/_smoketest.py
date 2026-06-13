import time, torch
from voxcpm import VoxCPM
import soundfile as sf

dev = "mps" if torch.backends.mps.is_available() else "cpu"
print(f"device={dev}", flush=True)

t0 = time.time()
model = VoxCPM.from_pretrained("openbmb/VoxCPM2", load_denoiser=False,
                               optimize=False, device=dev)
sr = model.tts_model.sample_rate
print(f"model loaded in {time.time()-t0:.0f}s, sr={sr}", flush=True)

# English
t1 = time.time()
wav = model.generate(text="VoxCPM2 brings multilingual support and controllable voice cloning.",
                     cfg_value=2.0, inference_timesteps=10)
sf.write("output.wav", wav, sr)
print(f"EN generated in {time.time()-t1:.0f}s -> output.wav ({len(wav)/sr:.1f}s audio)", flush=True)

# Turkish
t2 = time.time()
tr = "Merhaba, bu bir Türkçe seslendirme testidir. VoxCPM2 ile uzun kitapları sesli kitaba dönüştürebilirsiniz."
wav2 = model.generate(text=tr, cfg_value=2.0, inference_timesteps=10)
sf.write("turkce_test.wav", wav2, sr)
print(f"TR generated in {time.time()-t2:.0f}s -> turkce_test.wav ({len(wav2)/sr:.1f}s audio)", flush=True)
print("ALL DONE", flush=True)
