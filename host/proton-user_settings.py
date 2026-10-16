
# BEGIN Vibepollo stream limiter
user_settings = globals().get("user_settings", {})
try:
    from _vibepollo_frame_limiter import apply as _vibepollo_apply_limiter
    _vibepollo_apply_limiter(globals())
except Exception:
    pass  # A missing host must never prevent a game from starting.
# END Vibepollo stream limiter
