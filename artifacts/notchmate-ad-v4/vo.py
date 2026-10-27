import asyncio, json, edge_tts
LINES = [
 "Этот вырез на Макбуке умеет больше, чем ты думаешь.",
 "Наводишь курсор — и вот твоя музыка.",
 "Встречи на сегодня.",
 "Заметки и списки.",
 "Даже сон и пульс — прямо с часов.",
 "А ещё тут живёт помощник.",
 "Он танцует под твою музыку!",
 "Нотчмейт — бесплатно для Мака.",
 "Ссылка в профиле.",
 "Сохрани, чтобы не потерять!",
]
async def one(i, text):
    c = edge_tts.Communicate(text, "ru-RU-SvetlanaNeural", rate="+10%", boundary="WordBoundary")
    words, audio = [], b""
    async for ch in c.stream():
        if ch["type"] == "audio": audio += ch["data"]
        elif ch["type"] == "WordBoundary":
            words.append((ch["offset"] / 1e7, (ch["offset"] + ch["duration"]) / 1e7, ch["text"]))
    open(f"l{i}.mp3", "wb").write(audio)
    return words
async def main():
    out = [await one(i, t) for i, t in enumerate(LINES, 1)]
    json.dump(out, open("words.json", "w"), ensure_ascii=False, indent=0)
asyncio.run(main())
