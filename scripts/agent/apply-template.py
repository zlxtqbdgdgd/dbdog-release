#!/usr/bin/env python3
"""把采集模板（定制层）合并进安装器渲染出的 conf.yaml。

用法: apply-template.py --template <模板.yaml> --conf <conf.yaml> [--check]

模板格式（每个键都可省）:
  instance:   # 深合并进 instances[] 的每一个元素
  log:        # 深合并进 logs[] 的每一个元素

合并规则: 映射递归合并，其余（标量/列表）模板覆盖。幂等——同一模板套多少次结果一样。
--check 只比对不写盘，有差异退出码 1（升级后用它判断要不要重套）。
输出文件不保留注释（pyyaml 限制）；注释以模板文件为准，机器上那份是生成物。
"""
import argparse, copy, hashlib, os, sys, tempfile
import yaml


def deep_merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            deep_merge(dst[key], value)
        else:
            dst[key] = copy.deepcopy(value)
    return dst


def apply(conf, template):
    out = copy.deepcopy(conf)
    for inst in out.get("instances") or []:
        deep_merge(inst, template.get("instance") or {})
    for log in out.get("logs") or []:
        deep_merge(log, template.get("log") or {})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--conf", required=True)
    ap.add_argument("--check", action="store_true", help="只比对不写盘；有差异退出 1")
    args = ap.parse_args()

    with open(args.template, "rb") as f:
        raw = f.read()
    template = yaml.safe_load(raw) or {}
    digest = hashlib.sha256(raw).hexdigest()[:12]
    with open(args.conf, encoding="utf-8") as f:
        conf = yaml.safe_load(f) or {}

    merged = apply(conf, template)
    if merged == conf:
        print(f"已是模板 {os.path.basename(args.template)}@{digest} 的结果，无变化")
        return 0
    if args.check:
        print(f"与模板 {os.path.basename(args.template)}@{digest} 不一致，需要重套", file=sys.stderr)
        return 1

    body = (f"# 由 apply-template.py 生成：{os.path.basename(args.template)}@{digest}。"
            f"本文件是生成物，注释见模板；升级后重跑同一命令即可恢复。\n"
            + yaml.safe_dump(merged, allow_unicode=True, sort_keys=False, default_flow_style=False))
    st = os.stat(args.conf)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(args.conf)), prefix=".conf.yaml.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, args.conf)
    except BaseException:
        os.unlink(tmp)
        raise
    print(f"已套用 {os.path.basename(args.template)}@{digest} → {args.conf}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
