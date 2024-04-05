use clap::{Parser, Subcommand};

use std::path::PathBuf;

const HELP_TEMPLATE: &str = "\
{before-help}{name} {version}
{author-with-newline}{about-with-newline}
{usage-heading} {usage}

{all-args}{after-help}
";

#[derive(Clone, Debug, Parser)]
#[command(author, version, about, long_about = None)]
#[command(
    propagate_version = true,
    infer_long_args = true,
    infer_subcommands = true,
    flatten_help = true
)]
#[command(help_template = HELP_TEMPLATE)]
pub struct Options {
    #[arg(
        short,
        long,
        value_name = "PATH",
        help = "kconfig config file, default stdin"
    )]
    pub config: Option<PathBuf>,
    #[arg(short, long, value_name = "PATH", help = "output file, default stdout")]
    pub output: Option<PathBuf>,
    #[arg(short, long, help = "whether to ignore `# CONFIG_X is not set`")]
    pub ignore_not_set: bool,
    #[arg(short, long, help = "ignore ill-formed lines")]
    pub relaxed: bool,
    #[arg(short, long, help = "add comments to distinguish string/hex/int")]
    pub type_comment: bool,

    #[command(subcommand)]
    pub command: Option<Commands>,
}

#[derive(Clone, Debug, Subcommand)]
pub enum Commands {
    Completion(CompletionOptions),
}

#[derive(Clone, Debug, Parser)]
#[command(about = "Do retention")]
#[command(arg_required_else_help = true)]
pub struct RunOptions {}

#[derive(Clone, Debug, Parser)]
#[command(about = "Generate shell completions")]
#[command(arg_required_else_help = true)]
pub struct CompletionOptions {
    pub shell: clap_complete::Shell,
}
