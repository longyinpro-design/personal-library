#!/usr/bin/env python3
"""Benchmark substring search on a library-shaped database.

Builds a throwaway SQLite file with the same items table and trigram FTS index
the app creates, fills it with synthetic Chinese documents, then times the two
query paths: three or more characters go through the FTS index, one or two
characters fall back to a full-table LIKE scan.

    ./script/search-benchmark.py --documents 10000 --chars 20000

The output is JSON so CI can compare runs; the p95 of the short-query path is
what the roadmap budget of 300 ms refers to.
"""

import argparse
import json
import os
import random
import sqlite3
from concurrent.futures import ThreadPoolExecutor
import statistics
import tempfile
import threading
import time

# A few thousand common Chinese characters: enough variety that bigrams repeat
# the way they do in real prose, so the fallback scan measures realistic work.
COMMON = (
    "的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里"
    "用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从想实"
    "日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政"
    "美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东声提立及比员"
    "解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再感建务做接必场件"
    "计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书非则听白却界达光放强即像难且权思王象"
    "完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改"
    "收根干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远叫台单影具罗字爱击流备兵连调"
    "深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火断精满支视消越器容照须九增研写称企"
    "八功吗包片史委乎查轻易早曾除农找装广显吧阿李标谈吃图念六引历首医局突专费号尽另周较注语仅考落青随选列"
    "武红响虽推势参希古众构房半节土投某案黑维革划敌致陈律足态护七兴派孩验责营星够章音跟志底站严巴例防族供"
    "效续施留讲型料终答紧黄绝奇察母京段依批群项故按河米围江织害斗双境客纪采举杀攻父苏密低朝友诉止细愿千值"
    "仍男钱破网热助倒育属坐帝限船脸职速刻乐否刚威毛状率甚独球般普怕弹校苦创假久错承印晚兰试股拿脑预谁益阳"
    "若哪微尼继送急血惊伤素药适波夜省初喜卫源食险待述陆习置居劳财环排福纳欢雷警获模充负云停木游龙树疑层冷"
    "洲冲射略范竟句室异激汉村哈策演简卡罪判担州静退既衣您宗积余痛检差富灵协角占配征修皮挥胜降阶审沉坚善妈"
    "刘读啊超免压银买皇养伊怀执副乱抗犯追帮宣佛岁航优怪香著田铁控税左右份穿艺背阵草脚概恶块顿敢守酒岛托央"
    "户烈洋哥索胡款靠评版宝座释景顾弟登货互付伯慢欧换闻危忙核暗姐介坏讨丽良序升监临亮露永呼味野架域沙掉括"
    "舰鱼杂误湾吉减编楚肯测败屋跑梦散温困剑渐封救贵枪缺楼县尚毫移娘朋画班智亦耳恩短掌恐遗固席松秘谢鲁遇康"
    "虑幸均销钟诗藏赶剧票损忽巨炮旧端探湖录叶春乡附吸予礼港雨呀板庭妇归睛饭额含顺输摇招婚脱补谓督毒油疗旅"
    "泽材灭逐莫笔亡鲜词圣择寻厂睡博勒烟授诺伦岸奥唐卖俄炸载洛健堂旁宫喝借君禁阴园谋宋避抓荣姑孙逃牙束跳顶"
)


def build_database(path: str, documents: int, chars: int, seed: int) -> None:
    random.seed(seed)
    db = sqlite3.connect(path)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE items (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
            relative_path TEXT, body TEXT NOT NULL, extraction_note TEXT,
            byte_count INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            collection_id TEXT REFERENCES collections(id), favorite INTEGER NOT NULL DEFAULT 0,
            image_base_path TEXT, deleted_at REAL, fingerprint TEXT
        );
        CREATE VIRTUAL TABLE items_fts USING fts5(
            title, body, content='items', content_rowid='rowid',
            tokenize='trigram', detail=none
        );
        CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
        END;
        """
    )
    start = time.perf_counter()
    db.execute("BEGIN")
    for index in range(documents):
        body = "".join(random.choice(COMMON) for _ in range(chars))
        # Prose has a handful of recurring two-character words; plant six of them
        # so short queries find hits the way they do in a real library.
        words = ["".join(random.choice(COMMON) for _ in range(2)) for _ in range(6)]
        positions = sorted(random.randrange(chars - 2) for _ in range(6))
        body = list(body)
        for word, position in zip(words, positions):
            body[position:position + 2] = word
        db.execute(
            "INSERT INTO items (id, title, kind, body, byte_count, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
            (f"item-{index}", f"资料 {index}", "markdown", "".join(body), chars * 3, index, index),
        )
    db.execute("COMMIT")
    db.execute("INSERT INTO items_fts(items_fts) VALUES('optimize')")
    db.commit()
    print(
        json.dumps(
            {"built_seconds": round(time.perf_counter() - start, 1),
             "database_megabytes": round(os.path.getsize(path) / 1_000_000, 1)}
        ),
        flush=True,
    )
    db.close()


WORKERS = 4


def connect(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path, check_same_thread=False)
    db.execute("PRAGMA mmap_size = 268435456")  # What the app sets.
    return db


def scan_slices(path: str) -> list[tuple[int, int]]:
    db = connect(path)
    low, high = db.execute("SELECT min(rowid), max(rowid) FROM items").fetchone()
    db.close()
    step = (high - low) // WORKERS + 1
    return [(low + index * step, min(high, low + (index + 1) * step - 1)) for index in range(WORKERS)]


def timed(sql: str, parameters: tuple, path: str) -> float:
    db = connect(path)
    started = time.perf_counter()
    db.execute(sql, parameters).fetchall()
    elapsed = (time.perf_counter() - started) * 1000
    db.close()
    return elapsed


def split_scan(term: str, path: str, slices: list[tuple[int, int]]) -> float:
    """The app's fallback path: the same WHERE clause over four rowid ranges."""
    sql = "SELECT id FROM items WHERE (title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\') AND rowid BETWEEN ? AND ?"
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        pattern = f"%{term}%"
        list(pool.map(lambda span: timed(sql, (pattern, pattern, span[0], span[1]), path), slices))
    return (time.perf_counter() - started) * 1000


def measure(path: str, documents: int, rounds: int, samples: int) -> dict:
    random.seed(7)
    chars = "".join(random.choice(COMMON) for _ in range(20))
    slices = scan_slices(path)

    short = []
    split = []
    long = []
    for index in range(samples):
        term = chars[index:index + 2]
        for _ in range(rounds):
            short.append(timed("SELECT id FROM items WHERE body LIKE ?", (f"%{term}%",), path))
            split.append(split_scan(term, path, slices))
        three = chars[index:index + 3]
        long.append(timed("SELECT rowid FROM items_fts WHERE items_fts MATCH ?", (f'"{three}"',), path))

    def p95(values: list[float]) -> float:
        return round(statistics.quantiles(values, n=20)[18], 1) if len(values) > 1 else round(values[0], 1)

    return {
        "documents": documents,
        "two_character_p50_ms": round(statistics.median(short), 1),
        "two_character_p95_ms": p95(short),
        "two_character_max_ms": round(max(short), 1),
        "split_scan_p50_ms": round(statistics.median(split), 1),
        "split_scan_p95_ms": p95(split),
        "three_character_p95_ms": p95(long),
        "budget_ms": 300,
        "within_budget": p95(split) <= 300,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--documents", type=int, default=10000)
    parser.add_argument("--chars", type=int, default=20000)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--seed", type=int, default=20261024)
    parser.add_argument("--database", default=None, help="reuse a database built by an earlier run")
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory() as directory:
        path = arguments.database or os.path.join(directory, "benchmark.sqlite")
        if not os.path.exists(path):
            build_database(path, arguments.documents, arguments.chars, arguments.seed)
        print(json.dumps(measure(path, arguments.documents, arguments.rounds, arguments.samples)), flush=True)


if __name__ == "__main__":
    main()
