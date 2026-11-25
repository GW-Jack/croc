import Common

# A defaulted field (`??`) and an optional field (`?:`).
ServerConfig := { host : Str, port : U16 ?? 8080, timeout_ms ?: U64 }.{
	describe : ServerConfig -> Str
	describe = |config| {
		timeout_str = match config.?timeout_ms {
			Ok(ms) => "${ms.to_str()}ms"
			Err(MissingField) => "no timeout"
		}

		Common.label(config.host, "${config.port.to_str()} (${timeout_str})")
	}
}
