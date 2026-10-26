"""Render the actual parser audit as a self-contained, searchable Arabic report."""
import collections
import html
import json
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
rows = data["cases"]
assert data.get("schema_version") == 2, "Run the updated ScenarioAudit before rendering"
assert len(rows) == 100 and {row["id"] for row in rows} == {f"D{i:03d}" for i in range(1, 101)}
escape = lambda value: html.escape(str(value), quote=True)
domains = {"shopping": "التسوق وقوائم الشراء", "reminder": "التذكيرات والتنبيهات",
           "calendar": "المواعيد والتقويم", "work": "الشغل والمتابعة",
           "expense": "المصاريف والمشتريات المدفوعة", "memory": "معلومات أحب أفتكرها",
           "project": "المشاريع ونظام الشغل", "idea": "حفظ الأفكار وتطويرها",
           "home_recipe": "البيت والوصفات", "safety": "النفي والتعديل ونقص المعلومات"}
statuses = {"auto_match": "مطابق للحقول المطلوبة", "safe_review": "محجوز بأمان للمراجعة",
            "review_gap": "أمر واضح توقف للمراجعة", "interpretation_gap": "تفسير أو بيانات تحتاج تحسين",
            "capability_gap": "يحتاج قدرة أو حقول إضافية", "review_gate_gap": "يحتاج مراجعة قبل التنفيذ"}
languages = {"ar": "عربي", "en": "English", "mixed": "عربي وEnglish"}


def details(actions, empty_message="لا توجد مسودات."):
    output = []
    for item in actions:
        name = f'{item.get("kind", "?")} · {item.get("title", "")}'
        fields = []
        for key, value in item.items():
            if key in ("kind", "title"):
                continue
            if isinstance(value, (list, dict)):
                value = json.dumps(value, ensure_ascii=False)
            fields.append(f"{key}: {value}")
        output.append(f'<li><b dir="auto">{escape(name)}</b><div class="fields" dir="auto">'
                      + "<br>".join(map(escape, fields)) + "</div></li>")
    return "<ul>" + "".join(output) + "</ul>" if output else f"<p>{escape(empty_message)}</p>"


cards = []
for row in rows:
    expected = row["expected"]
    assert row["status"] in statuses and isinstance(row["actual"], list)
    assert isinstance(row["automatic_candidates"], list)
    assert row["executed_actions"] == [], "This report describes a parser-only dry run"
    assert row["state_consumed"] is False, "The stateless runner cannot claim fixture-state execution"
    if expected["mode"] == "clarify":
        assert expected["actions"] == [] and expected["executed_actions"] == []
        assert isinstance(expected["pending_actions"], list)
        assert row["review_gate_passed"] == all(item["requires_review"] for item in row["actual"])
    if row.get("state") is not None:
        assert row.get("warnings"), "Unconsumed desired fixture state must be visible"
    if row.get("capability_gaps"):
        assert row["status"] not in ("auto_match", "safe_review"), "Capability gaps are not feature passes"
    issue_items = [f"<li>{escape(text)}</li>" for text in row["differences"]]
    missing = row.get("capability_gaps", [])
    if missing:
        issue_items.append(f'<li>قدرات إضافية مطلوبة: <span dir="ltr">{escape(", ".join(missing))}</span></li>')
    question = expected.get("question")
    pending = expected.get("pending_actions", [])
    warnings = "".join(f'<li>{escape(text)}</li>' for text in row.get("warnings", []))
    cards.append(f'''
    <article data-domain="{escape(row['domain'])}" data-language="{escape(row['language'])}"
             data-status="{escape(row['status'])}">
      <header><span dir="ltr">{escape(row['id'])}</span><span>{escape(domains[row['domain']])}</span>
        <span>{escape(languages[row['language']])}</span><strong class="{escape(row['status'])}">{escape(statuses[row['status']])}</strong></header>
      <h2 dir="auto">{escape(row['utterance'])}</h2>
      <p class="situation">{escape(row['situation'])}</p>
      <p><b>المطلوب:</b> {escape(expected['outcome'])}</p>
      {f'<p><b>سؤال التوضيح:</b> {escape(question)}</p>' if question else ''}
      <details><summary>الإجراءات المطلوبة بعد اكتمال المعلومات</summary>{details(expected['actions'], 'لا إجراء مطلوب قبل التوضيح.')}</details>
      {f'<details><summary>مسودات النية المعلّقة المطلوبة — غير منفّذة</summary>{details(pending, "لم تتحدد نية إجراء قبل التوضيح.")}</details>' if expected['mode'] == 'clarify' else ''}
      <details><summary>مسودات المنظّم الحالي — لم تُنفّذ</summary>{details(row['actual'])}
        {'<ul class="issues">' + ''.join(issue_items) + '</ul>' if issue_items else ''}</details>
      <details><summary>المسودات المؤهلة للحفظ تلقائيًا — غير منفّذة هنا</summary>{details(row['automatic_candidates'], 'لا مسودات مؤهلة للحفظ التلقائي.')}</details>
      <p class="execution"><b>الإجراءات المنفّذة في هذا الاختبار:</b> لا شيء <code dir="ltr">executed_actions = []</code></p>
      {'<ul class="warnings">' + warnings + '</ul>' if warnings else ''}
      <p class="note">{escape(row.get('note', ''))}</p>
    </article>''')

summary = "".join(f'<div><b>{data["summary"].get(key, 0)}</b><span>{escape(label)}</span></div>'
                  for key, label in statuses.items())
assert collections.Counter(row["status"] for row in rows) == collections.Counter(data["summary"]), "Summary does not match cases"
options = lambda mapping: "".join(f'<option value="{escape(key)}">{escape(value)}</option>' for key, value in mapping.items())
document = '''<!doctype html>
<html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>100 سيناريو يومي لفهم وتنظيم الكلام في MixCapture</title>
<style>
:root{color-scheme:light dark;--bg:#faf6ef;--card:#fff;--ink:#16302f;--muted:#596967;--line:#e7e0d3;--teal:#0f766e}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.8 system-ui,"Segoe UI",Arial,sans-serif}
main{max-width:1050px;margin:auto;padding:30px 18px}h1{font-size:clamp(25px,4vw,38px);line-height:1.4}h2{font-size:20px;line-height:1.7;margin:14px 0}
p{margin:10px 0}a{color:var(--teal)}.intro,article,.legend{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:22px;margin:18px 0}
.summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}.summary div{border:1px solid var(--line);border-radius:14px;padding:14px;background:var(--card)}
.summary b{display:block;font-size:30px;color:var(--teal)}.summary span{font-size:14px}.filters{display:flex;gap:10px;flex-wrap:wrap;position:sticky;top:0;background:var(--bg);padding:12px 0;z-index:1}
input,select{font:inherit;min-height:46px;border:1px solid var(--line);border-radius:10px;padding:8px 12px;background:var(--card);color:var(--ink)}input{flex:1;min-width:210px}select{max-width:100%}
header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;font-size:13px;color:var(--muted)}header span,header strong{padding:3px 9px;border-radius:9px;background:var(--bg)}
.auto_match{color:#087244}.safe_review,.review_gap,.capability_gap{color:#9b5804}.interpretation_gap,.review_gate_gap{color:#b3261e}
.situation,.note{color:var(--muted);font-size:15px}.fields{font-size:14px;overflow-wrap:anywhere}.issues{color:#b3261e}summary{cursor:pointer;color:var(--teal);padding:8px 0}details+details{border-top:1px solid var(--line)}
.execution,.warnings{font-size:14px}.execution{background:var(--bg);border-radius:10px;padding:8px 12px}.warnings{border-inline-start:3px solid #9b5804;padding-inline-start:22px;color:var(--muted)}
li{margin:6px 0}[hidden]{display:none!important}.empty{display:none}footer{font-size:14px;color:var(--muted);margin-top:25px}
@media(prefers-color-scheme:dark){:root{--bg:#151413;--card:#22211f;--ink:#e9f2f0;--muted:#b9c5c2;--line:#34322e;--teal:#5eead4}.auto_match{color:#64deb0}.safe_review,.review_gap,.capability_gap{color:#fbbf24}.issues,.interpretation_gap,.review_gate_gap{color:#ffb4ab}}
@media print{.filters{display:none}article{break-inside:avoid}body{font-size:12px}}
</style><main>
<h1>100 سيناريو يومي لفهم وتنظيم الكلام في MixCapture</h1>
<section class="intro"><p>مواقف واقعية بالشغل والبيت والمواعيد والتسوق والمصاريف والأفكار، بالعربي والإنجليزي والمكس. لكل موقف تصرّف مقصود وسؤال توضيح عند الحاجة.</p>
<p><b>الأرقام تقيس قواعد فهم النص الحالي فقط.</b> السيناريوهات مواصفات للسلوك المطلوب؛ وجود السيناريو لا يعني أن التطبيق يدعمه. لم تُختبر هنا 100 تسجيلة صوت، ولم تُرسل إشعارات أو تُكتب مواعيد أو بيانات فعلية.</p>
<p>«محجوز بأمان للمراجعة» تعني أن التنفيذ التلقائي توقف؛ لا تثبت أن حوار التوضيح أو تطوير الأفكار متاح. عناوين الملاحظات مرجع بشري، مع التحقق من حفظ النص الأصلي كاملًا.</p>
<p>في حالات طلب التوضيح، قائمة الإجراءات المطلوبة والمنفّذة فارغة؛ النيات في <span dir="ltr">pending_actions</span> مجرد مسودات غير منفذة. الحجز للمراجعة لا يحوّل قدرة ناقصة مثل تطوير فكرة أو تذكير موقع أو البحث في المصاريف إلى ميزة ناجحة.</p>
<p>الحالة التأليفية في D044 مواصفة لاختبار لاحق يعتمد على بيانات موجودة. المنظّم الحالي لا يستهلكها؛ لم يُختبر نقل المهمة أو الحفاظ على هويتها أو تعديل أي بيانات.</p>
<p>مرجع الوقت الثابت: الاثنين 26 أكتوبر 2026، الساعة 09:00 صباحًا بتوقيت القاهرة. «بكرة» تعني 27 أكتوبر. يوم التسوق لا يُحوَّل إلى ساعة تنبيه افتراضية.</p></section>
<section class="summary">SUMMARY</section>
<div class="filters"><input id="q" aria-label="ابحث في السيناريوهات" placeholder="ابحث عن موقف أو كلمة…"><select id="domain" aria-label="مجموعة المواقف"><option value="">كل المجموعات</option>DOMAINS</select>
<select id="language" aria-label="لغة الكلام"><option value="">كل اللغات</option>LANGUAGES</select><select id="status" aria-label="نتيجة الفهم الحالي"><option value="">كل النتائج</option>STATUSES</select></div>
<p id="count" role="status">100 من 100 سيناريو</p><section id="cases">CARDS</section><footer>البيانات أمثلة مصطنعة. لا توجد تسجيلات أو بيانات شخصية. الفهم الحالي أُخذ من OrganizerParser الفعلي؛ الفجوات ظاهرة بدل تغيير التوقعات لتبدو ناجحة.</footer>
</main><script>
const controls=['q','domain','language','status'].map(id=>document.getElementById(id));
function filter(){const [q,d,l,s]=controls.map(el=>el.value.toLocaleLowerCase());let n=0;for(const card of document.querySelectorAll('article')){const match=(!q||card.textContent.toLocaleLowerCase().includes(q))&&(!d||card.dataset.domain===d)&&(!l||card.dataset.language===l)&&(!s||card.dataset.status===s);card.hidden=!match;if(match)n++;}document.getElementById('count').textContent=n+' من 100 سيناريو';}
for(const el of controls)el.addEventListener('input',filter);
</script></html>'''
for key, value in {"SUMMARY": summary, "DOMAINS": options(domains), "LANGUAGES": options(languages),
                   "STATUSES": options(statuses), "CARDS": "".join(cards)}.items():
    document = document.replace(key, value)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(document, encoding="utf-8")
assert document.count("<article ") == 100
print(f"Rendered 100 scenarios: {target}")
