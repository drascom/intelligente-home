FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt /app/brain/requirements.txt
RUN pip install --no-cache-dir -r /app/brain/requirements.txt

COPY . /app/brain/

EXPOSE 8800
CMD ["python", "-m", "brain.main"]
