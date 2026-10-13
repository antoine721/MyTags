import json, uuid
NS = uuid.UUID("6d1f4c1e-2b7a-4c55-9a3e-5b0c2f9e7a10")
def uid(s): return str(uuid.uuid5(NS, s))
T = "2026-10-08T00:00:00.000Z"
fields_spec = [
  dict(key="genre", name="Genre", kind="single", target_tag="GENRE", target_slot=None, required=True, visible=True, artist_level=True, is_advance_trigger=False, default=None,
       options=["RAP FR", "RAP US", "POP", "BOUYON", "SHATTA", "ZOUKOMPA"]),
  dict(key="couleur", name="Couleur", kind="single", target_tag="GROUPING", target_slot=None, required=True, visible=True, artist_level=False, is_advance_trigger=False, default=None,
       options=[("VERT","systemGreen"),("JAUNE","systemYellow"),("ROUGE","systemRed"),("BLEU","systemBlue"),("VIOLET","systemPurple")]),
  dict(key="pays", name="Pays", kind="single", target_tag="COMMENT", target_slot=1, required=True, visible=True, artist_level=True, is_advance_trigger=False, default=None,
       options=["FR", "US", "UK"]),
  dict(key="type", name="Type", kind="single", target_tag="COMMENT", target_slot=2, required=True, visible=True, artist_level=False, is_advance_trigger=False, default=None,
       options=["EXTEND", "REMIX", "EDIT"]),
  dict(key="attribut", name="Attribut", kind="single", target_tag="COMMENT", target_slot=3, required=False, visible=True, artist_level=False, is_advance_trigger=False, default="()",
       options=["NICHE", "SEXY", "TIKTOK", "ELECTROPOP", "AFRO", "SINGALONG", "()"]),
  dict(key="note", name="Note", kind="rating", target_tag="RATING", target_slot=None, required=True, visible=True, artist_level=False, is_advance_trigger=True, default=None, options=[]),
  dict(key="actualite", name="Actualité", kind="single", target_tag="COMMENT", target_slot=None, required=False, visible=False, artist_level=False, is_advance_trigger=False, default=None,
       options=["ARCHIVE"]),
]
fields, options = [], []
for pos, f in enumerate(fields_spec):
    fid = uid("field:" + f["key"])
    default_id = None
    for opos, o in enumerate(f["options"]):
        value, color = (o if isinstance(o, tuple) else (o, None))
        oid = uid(f"option:{f['key']}:{value}")
        if f["default"] == value: default_id = oid
        options.append(dict(id=oid, field_id=fid, value=value, label=value, color=color, aliases=[], position=opos, archived=False, updated_at=T, deleted_at=None))
    fields.append(dict(id=fid, key=f["key"], name=f["name"], kind=f["kind"], target_tag=f["target_tag"], target_slot=f["target_slot"],
                       required=f["required"], visible=f["visible"], position=pos, default_option_id=default_id,
                       is_advance_trigger=f["is_advance_trigger"], artist_level=f["artist_level"], updated_at=T, deleted_at=None))
F = {f["key"]: f["id"] for f in fields}
O = lambda fk, v: uid(f"option:{fk}:{v}")
rules = [
  dict(name="Titre « extended » → Type EXTEND", condition={"type":"title_contains","patterns":["extended","extend"]}, action={"field_id":F["type"],"option_id":O("type","EXTEND")}),
  dict(name="Titre « remix » → Type REMIX", condition={"type":"title_contains","patterns":["remix","rmx"]}, action={"field_id":F["type"],"option_id":O("type","REMIX")}),
  dict(name="Titre « edit » → Type EDIT", condition={"type":"title_contains","patterns":["edit"]}, action={"field_id":F["type"],"option_id":O("type","EDIT")}),
  dict(name="Genre RAP FR → Pays FR", condition={"type":"field_equals","field_id":F["genre"],"option_id":O("genre","RAP FR")}, action={"field_id":F["pays"],"option_id":O("pays","FR")}),
  dict(name="Genre RAP US → Pays US", condition={"type":"field_equals","field_id":F["genre"],"option_id":O("genre","RAP US")}, action={"field_id":F["pays"],"option_id":O("pays","US")}),
]
rules = [dict(id=uid("rule:"+str(i)), name=r["name"], enabled=True, position=i, condition=r["condition"], action=r["action"], mode="suggest", updated_at=T, deleted_at=None) for i, r in enumerate(rules)]
views = [
  dict(key="a_completer", name="À compléter", filters={"special":["incomplete"]}, sort={"key":"artist","ascending":True}, skip_complete=True),
  dict(key="non_tagues", name="Non tagués", filters={"special":["untagged"]}, sort={"key":"artist","ascending":True}, skip_complete=False),
  dict(key="a_appliquer", name="À appliquer", filters={"special":["to_apply"]}, sort={"key":"artist","ascending":True}, skip_complete=False),
  dict(key="comment_a_verifier", name="COMMENT à vérifier", filters={"special":["comment_non_conforme"]}, sort={"key":"artist","ascending":True}, skip_complete=False),
]
views = [dict(id=uid("view:"+v["key"]), name=v["name"], filters=v["filters"], sort=v["sort"], skip_complete=v["skip_complete"], position=i, builtin=True, updated_at=T, deleted_at=None) for i, v in enumerate(views)]
settings = [
  dict(key="comment.separator", value=" ", updated_at=T),
  dict(key="comment.empty_token", value="()", updated_at=T),
  dict(key="multi.separator", value="/", updated_at=T),
  dict(key="rating.write_formats", value=["mp3", "wav", "aiff"], updated_at=T),
]
cfg = dict(version=1, fields=fields, field_options=options, rules=rules, saved_views=views, settings=settings)
print(json.dumps(cfg, ensure_ascii=False, indent=2))
