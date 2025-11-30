import json
import os
import re
import textwrap
from pathlib import Path
from typing import Dict, List

import requests


def load_json(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data: Dict) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def load_text(path: Path) -> str:
    with path.open("r", encoding="utf-8") as f:
        return f.read().strip()


def build_system_prompt(prompt_text: str, memory: Dict, max_history: int) -> str:
    # 组装基础人格 + 记忆档案 + 历史摘要
    history_entries = memory.get("history", [])[-max_history:]
    history_text = "\n".join(
        "用户：{user}\n搭子：{assistant}\n记录：{record}".format(
            user=h.get("user", ""),
            assistant=h.get("assistant_visible", h.get("assistant", "")),
            record=h.get("assistant_memory", ""),
        ).strip()
        for h in history_entries
    ).strip()

    archive = memory.get("archive", "").strip()
    sections = [
        prompt_text,
        "【档案/记忆】",
        archive or "暂无",
        "【最近对话摘要】",
        history_text or "暂无",
    ]
    return "\n\n".join(sections)


def parse_reply(reply: str) -> tuple:
    # 拆分可见回复与记忆行。记忆行以【记录】/[记录]标记，若出现在正文中则截断。
    markers = ["【记录】", "[记录]"]
    idxs = [reply.find(m) for m in markers if m in reply]
    cut = min(idxs) if idxs else -1
    if cut != -1:
        visible = reply[:cut].strip()
        memory_text = reply[cut:].strip()
    else:
        # 逐行扫描，以防模型换行
        lines = reply.splitlines()
        mem_lines = []
        vis_lines = []
        for line in lines:
            if any(m in line for m in markers):
                mem_lines.append(line.strip())
            else:
                vis_lines.append(line)
        visible = "\n".join(vis_lines).strip() or reply.strip()
        memory_text = "\n".join(mem_lines).strip()
    return visible, memory_text


def clean_visible(text: str) -> str:
    # 去除 markdown 粗体/列表符号等，合并行，保留口语内容
    t = text.replace("**", "")
    t = re.sub(r"`+", "", t)
    lines = []
    for line in t.splitlines():
        line = line.strip()
        line = re.sub(r"^[\-\*\d\.\)\s]+", "", line)  # 去掉列表前缀
        if line:
            lines.append(line)
    t = " ".join(lines)
    t = re.sub(r"\s{2,}", " ", t).strip()
    return t


def call_one_api(
    api_base: str,
    api_key: str,
    model: str,
    system_prompt: str,
    user_content: str,
) -> str:
    url = api_base.rstrip("/") + "/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        "stream": False,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=120)
    resp.raise_for_status()
    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        raise RuntimeError(f"Unexpected response: {data}")


def fetch_models(api_base: str, api_key: str) -> List[str]:
    url = api_base.rstrip("/") + "/models"
    headers = {"Authorization": f"Bearer {api_key}"}
    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    items = data.get("data", [])
    models = []
    for item in items:
        mid = item.get("id")
        if mid:
            models.append(mid)
    return models


def choose_model(models: List[str]) -> str:
    if len(models) == 1:
        return models[0]
    print("检测到多个可用模型，请选择：")
    for idx, mid in enumerate(models, start=1):
        print(f"{idx}. {mid}")
    while True:
        sel = input(f"输入序号选择（默认 1）> ").strip()
        if sel == "":
            return models[0]
        if sel.isdigit() and 1 <= int(sel) <= len(models):
            return models[int(sel) - 1]
        print("输入无效，请重试。")


def ensure_memory_text(user_msg: str, assistant_visible: str, assistant_memory: str) -> str:
    if assistant_memory:
        return assistant_memory
    # 若模型未输出记录行，生成兜底记录
    vis = assistant_visible.strip()
    if len(vis) > 80:
        vis = vis[:80] + "..."
    return f"【记录】用户：{user_msg}；回复摘要：{vis}"


def update_memory(
    memory_path: Path,
    memory: Dict,
    user_msg: str,
    assistant_visible: str,
    assistant_memory: str,
    max_history: int,
) -> None:
    memory_text = ensure_memory_text(user_msg, assistant_visible, assistant_memory)
    history: List[Dict[str, str]] = memory.get("history", [])
    history.append(
        {
            "user": user_msg,
            "assistant_visible": assistant_visible,
            "assistant_memory": memory_text,
        }
    )
    if len(history) > max_history:
        history = history[-max_history:]
    memory["history"] = history
    memory["archive"] = memory_text
    save_json(memory_path, memory)


def main():
    base_dir = Path(__file__).parent
    config_path = base_dir / "config.json"
    if not config_path.exists():
        raise FileNotFoundError(
            "请先复制 config.example.json 为 config.json 并填写 api_base/api_key/model。"
        )
    cfg = load_json(config_path)
    api_base = cfg["api_base"]
    api_key = cfg["api_key"]
    model_cfg = cfg.get("model", "").strip()
    if model_cfg.lower() == "auto" or not model_cfg:
        available_models = fetch_models(api_base, api_key)
        if not available_models:
            raise RuntimeError("未能从 /models 获取可用模型，请在 config.json 明确填写 model。")
        model = choose_model(available_models)
        print(f"已选择模型：{model}（可在 config.json 设置 model 字段固定指定）")
    else:
        model = model_cfg
    prompt_file = base_dir / cfg.get("prompt_file", "ai_partner_template_compact.txt")
    memory_path = base_dir / cfg.get("memory_file", "memory.json")
    max_history = int(cfg.get("max_history", 6))

    prompt_text = load_text(prompt_file)
    if not memory_path.exists():
        save_json(memory_path, {"archive": "", "history": []})
    memory = load_json(memory_path)

    print("输入内容直接对话，回车空行退出。")
    while True:
        user_input = input("\n你想让搭子帮什么？\n> ").strip()
        if not user_input:
            print("退出对话。")
            break

        system_prompt = build_system_prompt(prompt_text, memory, max_history)
        assistant_reply = call_one_api(api_base, api_key, model, system_prompt, user_input)
        assistant_visible, assistant_memory = parse_reply(assistant_reply)
        assistant_visible = clean_visible(assistant_visible)

        print("\n--- 搭子回复 ---")
        print(textwrap.fill(assistant_visible, width=100))
        print("----------------\n")

        update_memory(
            memory_path,
            memory,
            user_input,
            assistant_visible,
            assistant_memory,
            max_history,
        )
        # 重新读内存以保持最新
        memory = load_json(memory_path)
    print(f"记忆保存在 {memory_path}")


if __name__ == "__main__":
    main()
