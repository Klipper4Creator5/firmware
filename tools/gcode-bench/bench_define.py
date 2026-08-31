#!/usr/bin/env python3
"""Drive klipper's real EXCLUDE_OBJECT_DEFINE path with stub printer objects.

Answers two questions: how long does a define block take to process, and
which function inside it spends the time.
"""
import argparse, cProfile, io, os, pstats, sys, time

def load_klippy(root):
    sys.path.insert(0, os.path.join(root, 'klippy'))
    sys.path.insert(0, root)
    import gcode as gcode_mod
    sys.modules.setdefault('klippy', type(sys)('klippy'))
    from extras import exclude_object
    return gcode_mod, exclude_object

class StubMutex:
    def __enter__(self): return self
    def __exit__(self, *a): return False
class StubReactor:
    def mutex(self): return StubMutex()
class StubGCodeMove:
    def set_move_transform(self, t, force=False): return None
class StubPrinter:
    config_error = RuntimeError
    def __init__(self): self.objects = {}
    def get_start_args(self): return {}
    def register_event_handler(self, *a): pass
    def get_reactor(self): return StubReactor()
    def lookup_object(self, name, default=None): return self.objects.get(name, default)
    def load_object(self, config, name): return self.objects.setdefault(name, StubGCodeMove())
    def send_event(self, *a): pass
    def invoke_shutdown(self, msg): raise RuntimeError(msg)
class StubConfig:
    def __init__(self, printer): self._printer = printer
    def get_printer(self): return self._printer

def build(root, quiet=True):
    gcode_mod, exclude_object = load_klippy(root)
    printer = StubPrinter()
    gc = gcode_mod.GCodeDispatch(printer)
    printer.objects['gcode'] = gc
    if not quiet:
        gc.register_output_handler(lambda m: sys.stderr.write(m + '\n'))
    else:
        gc.register_output_handler(lambda m: None)
    gc.is_printer_ready = True
    gc.gcode_handlers = gc.ready_gcode_handlers
    eo = exclude_object.ExcludeObject(StubConfig(printer))
    return gc, eo

def run(gc, lines):
    t0 = time.perf_counter()
    gc._process_commands(lines, need_ack=False)
    return time.perf_counter() - t0

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--klipper', required=True, help='klipper source root')
    p.add_argument('--objects', type=int, default=25)
    p.add_argument('--points', type=int, default=64)
    p.add_argument('--repeat', type=int, default=3)
    p.add_argument('--profile', action='store_true')
    a = p.parse_args()

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from genobjects import block
    lines = block(a.objects, a.points)
    nbytes = sum(len(l) for l in lines)

    best = None
    for _ in range(a.repeat):
        gc, eo = build(a.klipper)
        dt = run(gc, lines)
        best = dt if best is None else min(best, dt)
    print('objects=%d points=%d bytes=%d lines=%d'
          % (a.objects, a.points, nbytes, len(lines)))
    print('block wall time: %.3f s  (%.2f ms/object, %.1f us/byte)'
          % (best, best * 1000.0 / a.objects, best * 1e6 / nbytes))
    print('defined objects: %d' % len(eo.objects))

    if a.profile:
        gc, eo = build(a.klipper)
        pr = cProfile.Profile()
        pr.enable(); run(gc, lines); pr.disable()
        s = io.StringIO()
        pstats.Stats(pr, stream=s).sort_stats('tottime').print_stats(14)
        print(s.getvalue())

if __name__ == "__main__":
    main()
