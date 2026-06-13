FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

WORKDIR /app
RUN pip install --no-cache-dir \
    fastapi "uvicorn[standard]" anyio pydantic \
    numpy soundfile voxcpm

COPY server.py audiobook.py /app/
COPY voices/ /app/voices/

EXPOSE 8808
ENV VOX_DEVICE=cuda VOX_PORT=8808
CMD ["python", "server.py"]
