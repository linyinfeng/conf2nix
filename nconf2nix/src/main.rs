mod options;

use std::{
    cell::Cell,
    fs::OpenOptions,
    io::{stdin, stdout, BufRead, BufReader, BufWriter, Read, Write},
    process::exit,
};

use anyhow::Context;
use clap::{crate_name, CommandFactory, Parser};
use log::{error, warn};
use options::Options;

const HEADING: &str = "{ lib }:
let
  inherit (lib.kernel) yes no module freeform;
in {";
const FOOTING: &str = "}";
const INDENT: &str = "  ";

fn main() -> anyhow::Result<()> {
    let carte_name = crate_name!();

    let mut builder = pretty_env_logger::formatted_builder();
    let filters = match std::env::var("RUST_LOG") {
        Ok(f) => f,
        Err(_) => format!("{carte_name}=info"),
    };
    builder.parse_filters(&filters);
    builder.try_init()?;

    let options = Options::parse();

    match options.command {
        None => {
            let context = RunContext::new(options);
            context.run()
        }
        Some(options::Commands::Completion(gen_options)) => {
            generate_shell_completions(gen_options, carte_name)
        }
    }
}

#[derive(Debug)]
struct RunContext {
    options: Options,
    error_reported: Cell<bool>,
}

#[derive(Debug, Clone)]
struct Symbol {
    name: String,
    value: Value,
}

#[derive(Debug, Clone)]
enum Value {
    // we can not distinguish boolean and tristate values without parsing Kconfig
    // Boolean(bool),
    Tristate(Tristate),
    String(String),
    // currently, hex and int are directly saved as string
    Hex(String),
    Int(String),
}

#[derive(Debug, Clone, Copy)]
enum Tristate {
    No,
    Module,
    Yes,
}

impl RunContext {
    fn new(options: Options) -> Self {
        Self {
            options,
            error_reported: Cell::new(false),
        }
    }
    fn run(&self) -> anyhow::Result<()> {
        let config: Box<dyn Read> = match &self.options.config {
            None => Box::new(stdin()),
            Some(p) => Box::new(
                OpenOptions::new()
                    .read(true)
                    .open(p)
                    .with_context(|| format!("failed to open {p:?}"))?,
            ),
        };
        let mut output: Box<dyn Write> = match &self.options.output {
            None => Box::new(stdout()),
            Some(p) => Box::new(BufWriter::new(
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(p)
                    .with_context(|| format!("failed to open {p:?}"))?,
            )),
        };
        let mut symbols = Vec::new();

        /* main logic from scripts/kconfig/confdata.c conf_read_simple */
        let buffered = BufReader::new(config);
        for line_result in buffered.lines() {
            let line = line_result?;
            let processed = self.process_line(&line, &mut symbols)?;
            if !processed {
                self.ignore_line(&line);
            }
        }

        if !self.options.relaxed && self.error_reported.get() {
            exit(1)
        }

        writeln!(output, "{HEADING}",)?;
        for symbol in symbols {
            writeln!(
                output,
                r#"{INDENT}"{name}" = {v};"#,
                name = symbol.name,
                v = symbol.value.to_nix()
            )?;
        }
        writeln!(output, "{FOOTING}",)?;

        Ok(())
    }

    fn process_line(&self, line: &str, symbols: &mut Vec<Symbol>) -> anyhow::Result<bool> {
        if self.options.not_set_as_no && line.starts_with("# CONFIG_") {
            let end_of_symbol = match line.find(' ') {
                Some(i) => i,
                None => return Ok(false),
            };
            if !line[end_of_symbol + 1..].starts_with("is not set") {
                return Ok(false);
            }
            let symbol = line["# CONFIG_".len()..end_of_symbol].to_string();
            symbols.push(Symbol {
                name: symbol,
                value: Value::Tristate(Tristate::No),
            });
            Ok(true)
        } else if line.starts_with("CONFIG_") {
            let end_of_symbol = match line.find('=') {
                Some(i) => i,
                None => return Ok(false),
            };
            let symbol = line["CONFIG_".len()..end_of_symbol].to_string();
            let value_str = &line[end_of_symbol + 1..];
            let value = self.parse_value(value_str)?;
            symbols.push(Symbol {
                name: symbol,
                value,
            });
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn parse_value(&self, s: &str) -> anyhow::Result<Value> {
        /* logic differs from scripts/kconfig/confdata.c conf_set_sym_val */
        // since we don't know the type without parsing kconfig
        // we can only do heuristic parsing
        if let Some(tail) = s.strip_prefix('"') {
            // as string
            let mut unescaped = String::new();
            let mut chars = tail.chars();
            loop {
                let c = chars.next();
                match c {
                    Some('"') => break,
                    Some('\\') => match chars.next() {
                        Some(n) => unescaped.push(n),
                        None => anyhow::bail!("found invalid string escape sequence in value {s}"),
                    },
                    Some(o) => unescaped.push(o),
                    None => anyhow::bail!("found invalid string delimiter in value {s}"),
                }
            }
            self.ignore_remain(&chars.collect::<String>());
            Ok(Value::String(unescaped))
        } else if let Some(remain) = s.strip_prefix('n') {
            self.ignore_remain(remain);
            Ok(Value::Tristate(Tristate::No))
        } else if let Some(remain) = s.strip_prefix('m') {
            self.ignore_remain(remain);
            Ok(Value::Tristate(Tristate::Module))
        } else if let Some(remain) = s.strip_prefix('y') {
            self.ignore_remain(remain);
            Ok(Value::Tristate(Tristate::Yes))
        } else if Value::validate_int(s) {
            Ok(Value::Int(s.to_string()))
        } else if Value::validate_hex(s) {
            Ok(Value::Hex(s.to_string()))
        } else {
            anyhow::bail!("failed to parse value {s}")
        }
    }

    fn ignore_line(&self, line: &str) {
        let trimmed = line.trim();
        if !(trimmed.is_empty() || trimmed.starts_with('#')) {
            if self.options.relaxed {
                warn!("ignored ill-formed line: '{line}'")
            } else {
                error!("ill-formed line: '{line}'");
                self.error_reported.set(true);
            }
        }
    }

    fn ignore_remain(&self, remain: &str) {
        let trimmed = remain.trim();
        if !(trimmed.is_empty() || trimmed.starts_with('#')) {
            if self.options.relaxed {
                warn!("ignore tailing content: '{remain}'");
            } else {
                error!("unprocessed tailing content: '{remain}'");
                self.error_reported.set(true);
            }
        }
    }
}

impl Value {
    fn to_nix(&self) -> String {
        match &self {
            // Value::Boolean(b) => Tristate::from(b).to_nix(),
            Value::Tristate(t) => t.to_nix(),
            Value::String(s) => Self::to_nix_freeform_string(s),
            Value::Hex(s) => Self::to_nix_freeform_string(s),
            Value::Int(s) => Self::to_nix_freeform_string(s),
        }
    }

    fn validate_int(s: &str) -> bool {
        let digits = match s.strip_prefix('-') {
            Some(r) => r,
            None => s,
        };
        digits.chars().all(|c| c.is_ascii_digit())
    }

    fn validate_hex(s: &str) -> bool {
        if !s.starts_with("0x") && !s.starts_with("0X") {
            false
        } else {
            s[2..].chars().all(|c| c.is_ascii_hexdigit())
        }
    }

    fn to_nix_freeform_string(s: &str) -> String {
        format!(
            r#"freeform "{escaped}""#,
            escaped = Self::escape_string_to_nix(s)
        )
    }

    fn escape_string_to_nix(s: &str) -> String {
        let mut result = String::new();
        for c in s.chars() {
            match c {
                '"' | '\\' | '$' => result.push('\\'),
                _ => (),
            }
            result.push(c);
        }
        result
    }
}

impl From<bool> for Tristate {
    fn from(value: bool) -> Self {
        match value {
            true => Self::Yes,
            false => Self::No,
        }
    }
}

impl Tristate {
    fn to_nix(self) -> String {
        match self {
            Self::No => "no",
            Self::Module => "module",
            Self::Yes => "yes",
        }
        .to_string()
    }
}

fn generate_shell_completions(
    gen_options: options::CompletionOptions,
    command_name: &str,
) -> anyhow::Result<()> {
    let mut cli = options::Options::command();
    let mut stdout = std::io::stdout();
    clap_complete::generate(gen_options.shell, &mut cli, command_name, &mut stdout);
    Ok(())
}
