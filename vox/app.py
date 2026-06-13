#!/usr/bin/env python3
"""
app.py — VoxCPM2 Türkçe seslendirme / sesli kitap için Gradio arayüzü.

Çalıştır:
    source .venv/bin/activate
    python app.py            # yerel
    python app.py --share    # profesörün de erişebilmesi için public link (~72 saat)
"""
import argparse
import tempfile
import time

import numpy as np
import soundfile as sf
import torch
import gradio as gr

from audiobook import split_text
from epub2txt import extract_epub

# --- Model tek sefer yüklenir, bellekte tutulur -----------------------------
_MODEL = None
_SR = None


def get_model():
    global _MODEL, _SR
    if _MODEL is None:
        from voxcpm import VoxCPM
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        print(f"VoxCPM2 yükleniyor (device={dev})...")
        _MODEL = VoxCPM.from_pretrained(
            "openbmb/VoxCPM2", load_denoiser=False, optimize=False, device=dev
        )
        _SR = _MODEL.tts_model.sample_rate
        print("Model hazır.")
    return _MODEL, _SR


# --- Seslendirme ------------------------------------------------------------
def synth(text, reference, ref_text, cfg, timesteps, max_chars, gap_ms, progress=gr.Progress()):
    text = (text or "").strip()
    if not text:
        raise gr.Error("Lütfen seslendirilecek bir metin girin.")

    progress(0, desc="Model yükleniyor...")
    model, sr = get_model()

    chunks = split_text(text, max_chars=int(max_chars))
    if not chunks:
        raise gr.Error("Metinden cümle çıkarılamadı.")

    gen_kwargs = dict(cfg_value=float(cfg), inference_timesteps=int(timesteps))
    if reference:
        gen_kwargs["reference_wav_path"] = reference
        if (ref_text or "").strip():
            gen_kwargs["reference_text"] = ref_text.strip()

    gap = np.zeros(int(sr * int(gap_ms) / 1000), dtype=np.float32)
    parts = []
    t0 = time.time()
    for i, chunk in enumerate(chunks):
        progress((i) / len(chunks), desc=f"Parça {i+1}/{len(chunks)} seslendiriliyor...")
        wav = model.generate(text=chunk, **gen_kwargs)
        parts.append(np.asarray(wav, dtype=np.float32))
        parts.append(gap)

    full = np.concatenate(parts)
    out = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    sf.write(out, full, sr)
    dur = len(full) / sr
    elapsed = time.time() - t0
    info = (f"✅ {len(chunks)} parça · {dur:.1f} sn ses · {elapsed:.0f} sn'de üretildi "
            f"· {sr} Hz")
    return out, info


def synth_stream(text, reference, ref_text, cfg, timesteps, max_chars):
    """Canlı (streaming) seslendirme: ses parçaları üretildikçe yield edilir.
    Gradio bunları sırayla oynatır — tüm metnin bitmesini beklemez."""
    text = (text or "").strip()
    if not text:
        raise gr.Error("Lütfen seslendirilecek bir metin girin.")

    model, sr = get_model()
    chunks = split_text(text, max_chars=int(max_chars))
    if not chunks:
        raise gr.Error("Metinden cümle çıkarılamadı.")

    gen_kwargs = dict(cfg_value=float(cfg), inference_timesteps=int(timesteps))
    if reference:
        gen_kwargs["reference_wav_path"] = reference
        if (ref_text or "").strip():
            gen_kwargs["reference_text"] = ref_text.strip()

    for chunk in chunks:
        for piece in model.generate_streaming(text=chunk, **gen_kwargs):
            arr = np.asarray(piece, dtype=np.float32).reshape(-1)
            yield (sr, arr)


def load_file(file):
    """Yüklenen .txt veya .epub dosyasından metni döndür."""
    if file is None:
        return ""
    path = file.name if hasattr(file, "name") else file
    if path.lower().endswith(".epub"):
        return extract_epub(path)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


# --- Arayüz -----------------------------------------------------------------
with gr.Blocks(title="VoxCPM2 Türkçe Seslendirme") as demo:
    gr.Markdown(
        "# 🎙️ VoxCPM2 — Türkçe Metin Seslendirme\n"
        "Metni yapıştırın **veya** bir `.txt` / `.epub` yükleyin, ardından **Seslendir**'e basın.\n"
        "İsteğe bağlı: bir referans ses kaydı yükleyerek o sesi klonlayabilirsiniz."
    )

    with gr.Row():
        with gr.Column(scale=3):
            file_in = gr.File(label="Kitap/metin yükle (.txt veya .epub)",
                              file_types=[".txt", ".epub"])
            text_in = gr.Textbox(label="Metin", lines=12,
                                 placeholder="Seslendirilecek Türkçe metni buraya yazın veya yukarıdan dosya yükleyin...")
            with gr.Accordion("🎭 Ses klonlama (opsiyonel)", open=False):
                ref_audio = gr.Audio(label="Referans ses (5-15 sn temiz kayıt)",
                                     type="filepath", sources=["upload", "microphone"])
                ref_text = gr.Textbox(label="Referans kaydın metni (klonlamayı iyileştirir)",
                                      lines=2)
            with gr.Accordion("⚙️ Gelişmiş ayarlar", open=False):
                cfg = gr.Slider(1.0, 4.0, value=2.0, step=0.1, label="cfg_value (ifade gücü)")
                timesteps = gr.Slider(4, 30, value=10, step=1, label="inference_timesteps (kalite/hız)")
                max_chars = gr.Slider(100, 500, value=300, step=10, label="Parça başına maks. karakter")
                gap_ms = gr.Slider(0, 1000, value=300, step=50, label="Parçalar arası sessizlik (ms)")
            with gr.Row():
                btn = gr.Button("🔊 Seslendir", variant="primary")
                btn_stream = gr.Button("🔴 Canlı Seslendir (Stream)")

        with gr.Column(scale=2):
            audio_out = gr.Audio(label="Sonuç (tam dosya · indirilebilir)", type="filepath")
            info_out = gr.Markdown()
            audio_stream = gr.Audio(label="Canlı ses (üretildikçe çalar)",
                                    streaming=True, autoplay=True)

    gr.Markdown(
        "> ℹ️ İlk seslendirmede model belleğe yüklenir (~15 sn). "
        "Uzun metinler dakikalarca sürebilir — Mac'te yaklaşık 1.5 sn üretim / 1 sn ses."
    )

    file_in.change(load_file, inputs=file_in, outputs=text_in)
    btn.click(synth,
              inputs=[text_in, ref_audio, ref_text, cfg, timesteps, max_chars, gap_ms],
              outputs=[audio_out, info_out])
    btn_stream.click(synth_stream,
                     inputs=[text_in, ref_audio, ref_text, cfg, timesteps, max_chars],
                     outputs=audio_stream)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--share", action="store_true", help="Public paylaşım linki oluştur")
    ap.add_argument("--port", type=int, default=7860)
    args = ap.parse_args()
    demo.queue().launch(share=args.share, server_name="0.0.0.0", server_port=args.port)
