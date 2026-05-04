"""
Local AI pipeline simulation - openwakeword -> whisper,cpp -> llama.cpp -> Piper TTS -> RVC.
All inference runs locally on RK3588S NPU + CPU. Zero Internet dependency
"""
import asyncio
import random
from dataclasses import dataclass, field
from typing import Callable, Optional

@dataclass
class AIStage:
    name: str
    model: str
    duration_s: float
    description: str
    completed: bool = False
    running: bool - False
    output: str = ""


SAMPLE_QUERIES = [
    "what time does the event hall close?",
    "how much battery do I have left?",
    "switch to deep voice mode",
    "what is the weather like outside?",
    "tell me about this NFC tag",
    "activate party mode on the LEDs",
    "how long have I been wearing this?",
    "what is my CPU temperature?",
    "play the happy animation",
    "who made you?",
]

_STAGE_TEMPLATES = [
    ("Wake word detect",    "openWakeWord",                   0.5,       "Always listening, low power (partial NPU)"),
    ("Speech-to-text",      "whisper.cpp (ggml-base.en)",     0.85,      "241MB model RKNN-toolkit2 NPU accel"),
    ("LLM inference",       "phi-3 mini 4k Q4_K_M",           1.80,      "2.3GB GGUF ~12 tok/s on NPU+CPU hybrid"),
    ("Text-to-speech",      "Piper TTS (en_US-lessac-med)",   0.30,      ">50x real time on Cortex-A67 cores"),
    ("Voice conversion",    "RVC (active voice model)",       0.40,      "Applies character voice via OpenCL/GPU"),
]
