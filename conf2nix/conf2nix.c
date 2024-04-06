// SPDX-License-Identifier: GPL-2.0-only

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lkc.h"

#define CONF2NIX_INDENT "  "

// the same as confdata.c
enum output_n { OUTPUT_N, OUTPUT_N_AS_UNSET, OUTPUT_N_NONE };

struct options {
	enum output_n output_n;
	bool ignore_invisible;
	bool warn_unused;
	bool with_prompt;
	bool output_empty_string;
};

static void conf2nix(const struct options *options);
static void conf2nix_rec(const struct options *options, FILE *out,
			 struct menu *menu, const char *parent_prompt,
			 int level, bool *new_line_needed);
static void warn_unused(const struct options *options, struct menu *menu);
static void conf2nix_level_indicator(FILE *out, int level);
static void conf2nix_heading(FILE *out);
static void conf2nix_footing(FILE *out);
static void conf2nix_symbol(const struct options *options, FILE *out,
			    struct menu *menu, struct symbol *sym,
			    bool *new_line_needed);
static void conf2nix_before_symbol(FILE *out, bool *new_line_needed);
static void conf2nix_after_symbol(const struct options *options, FILE *out,
				  struct menu *menu);
static char *escape_string_value(const char *in);
static void usage(const char *progname, FILE *out);
static bool parse_bool_env(const char *progname, const char *env_name,
			   bool default_value);
static const size_t CONF2NIX_ITERATION = 3;

static void conf2nix(const struct options *options)
{
	size_t iter;
	size_t i;
	struct symbol *sym;

	/* calculate sym several times to make sure visibility is accurate */
	for (iter = 0; iter < CONF2NIX_ITERATION; iter++) {
		for_all_symbols(i, sym) sym_calc_value(sym);
	}

	bool new_line_needed = false;
	conf2nix_heading(stdout);
	conf2nix_rec(options, stdout, &rootmenu, NULL, 0, &new_line_needed);
	warn_unused(options, &rootmenu);
	conf2nix_footing(stdout);
}

static void conf2nix_rec(const struct options *options, FILE *out,
			 struct menu *menu, const char *parent_prompt,
			 int level, bool *new_line_needed)
{
	struct symbol *sym = NULL;
	struct menu *child;
	const char *prompt = NULL;
	const char *our_prompt = NULL;
	char *combined_prompt = NULL;
	FILE *inner_output;
	char *inner_output_ptr;
	size_t inner_output_size;
	int retval;

	if (options->ignore_invisible && !menu_is_visible(menu))
		return;

	/* before real output, output to an memory stream instead */
	/* if inner output is empty, we do not need to output prompt */
	inner_output = open_memstream(&inner_output_ptr, &inner_output_size);

	if (!menu_has_prompt(menu)) {
		/* menu without prompt can not be set by nixpkgs */
		goto conf_childs;
	}
	sym = menu->sym;
	if (!sym) {
		if (options->with_prompt) {
			our_prompt = menu_get_prompt(menu);
			/* do not append prompt of root menu, since it has no information included */
			if (level == 1)
				parent_prompt = NULL;
			if (parent_prompt) {
				size_t size = 0;
				const char *delimiter = " -> ";
				size += strlen(parent_prompt);
				size += strlen(delimiter);
				size += strlen(our_prompt);
				size += 1; /* length of '\0' */
				combined_prompt = malloc(size);
				snprintf(combined_prompt, size, "%s%s%s",
					 parent_prompt, delimiter, our_prompt);
				prompt = combined_prompt;
			} else {
				prompt = our_prompt;
			}
			*new_line_needed = false;
		}
		goto conf_childs;
	}

	/* since we already do this several times */
	/* we do not need to calculate value anymore */
	// sym_calc_value(sym);

	if (sym->flags & SYMBOL_WRITTEN)
		goto conf_childs;
	sym->flags |= SYMBOL_WRITTEN;

	conf2nix_symbol(options, inner_output, menu, sym, new_line_needed);
conf_childs:
	for (child = menu->list; child; child = child->next)
		conf2nix_rec(options, inner_output, child, prompt, level + 1,
			     new_line_needed);

	fclose(inner_output);
	if (inner_output_size > 0) {
		/* real output */
		if (prompt) {
			if (menu != &rootmenu)
				fprintf(out, "\n");
			conf2nix_level_indicator(out, level);
			fprintf(out, "%s\n", prompt);
		}
		/* include child output */
		retval = fputs(inner_output_ptr, out);
		if (retval == EOF) {
			fprintf(stderr, "failed writing to stream");
			exit(1);
		}
		if (our_prompt) {
			conf2nix_level_indicator(out, level);
			if (parent_prompt) {
				fprintf(out, "%s: ", parent_prompt);
			}
			fprintf(out, "end of %s\n", our_prompt);

			/* we need new line only after  */
			*new_line_needed = true;
		}
	}

	free(inner_output_ptr);
	free(combined_prompt);
}

static void warn_unused(const struct options *options, struct menu *menu)
{
	struct symbol *sym;
	struct menu *child;

	if (options->ignore_invisible && !menu_is_visible(menu))
		return;

	if (!menu_has_prompt(menu)) {
		/* do not check unused for symbols without prompt */
		/* since these symbols just can not be used */
		goto conf_childs;
	}
	sym = menu->sym;
	if (!sym)
		goto conf_childs;

	if (sym->name && sym->flags & SYMBOL_DEF_USER &&
	    !(sym->flags & SYMBOL_WRITTEN)) {
		fprintf(stderr, "unused symbol: '%s'\n", sym->name);
	}

conf_childs:
	for (child = menu->list; child; child = child->next)
		warn_unused(options, child);
}

static void conf2nix_level_indicator(FILE *out, int level)
{
	fprintf(out, CONF2NIX_INDENT "#");
	while (level-- > 0) {
		fprintf(out, "#");
	}
	fprintf(out, " ");
}

static void conf2nix_heading(FILE *out)
{
	fprintf(out, "{ lib }:\n");
	fprintf(out, "let\n");
	fprintf(out, "  inherit (lib.kernel) yes no module freeform;\n");
	fprintf(out, "in {\n");
}

static void conf2nix_footing(FILE *out)
{
	fprintf(out, "}\n");
}

static void conf2nix_symbol(const struct options *options, FILE *out,
			    struct menu *menu, struct symbol *sym,
			    bool *new_line_needed)
{
	const struct symbol_value *value = &sym->def[S_DEF_USER];
	const char *val;
	tristate tri;
	char *escaped = NULL;

	if (sym->name == NULL || sym->type == S_UNKNOWN ||
	    !(sym->flags & SYMBOL_DEF_USER))
		return;

	switch (sym->type) {
	case S_BOOLEAN:
	case S_TRISTATE:
		tri = value->tri;
		if (options->output_n != OUTPUT_N && tri == no) {
			if (options->output_n == OUTPUT_N_AS_UNSET)
				conf2nix_before_symbol(out, new_line_needed);
			fprintf(out, CONF2NIX_INDENT "# \"%s\" is not set",
				sym->name);
			conf2nix_after_symbol(options, out, menu);
			break;
		}
		conf2nix_before_symbol(out, new_line_needed);
		fprintf(out, CONF2NIX_INDENT "\"%s\" = ", sym->name);
		switch (tri) {
		case no:
			fprintf(out, "no");
			break;
		case mod:
			fprintf(out, "module");
			break;
		case yes:
			fprintf(out, "yes");
			break;
		default: // unreachable
		}
		fprintf(out, ";");
		conf2nix_after_symbol(options, out, menu);
		break;
	// all other types are treated as string
	// including S_STRING, S_HEX, and S_INT
	case S_STRING:
	case S_HEX:
	case S_INT:
		val = value->val;

		// this is a workaround for nixpkgs
		// the config system of nixpkgs does not handle `freefrom ""` properly
		if (*val == '\0' && !options->output_empty_string) {
			break;
		}

		escaped = escape_string_value(val);
		conf2nix_before_symbol(out, new_line_needed);
		fprintf(out, CONF2NIX_INDENT "\"%s\" = ", sym->name);
		fprintf(out, "freeform %s", escaped);
		fprintf(out, ";");
		conf2nix_after_symbol(options, out, menu);
	default: // unreachable
	}

	free(escaped);
}

static void conf2nix_after_symbol(const struct options *options, FILE *out,
				  struct menu *menu)
{
	const char *prompt;
	if (options->with_prompt) {
		prompt = menu_get_prompt(menu);
		if (prompt) {
			fprintf(out, " # %s", prompt);
		}
	}
	fprintf(out, "\n");
}

static void conf2nix_before_symbol(FILE *out, bool *new_line_needed)
{
	if (*new_line_needed)
		fprintf(out, "\n");
	*new_line_needed = false;
}

static char *escape_string_value(const char *in)
{
	const char *p;
	char *out;
	size_t len;

	len = strlen(in) + strlen("\"\"") + 1;

	p = in;
	while (1) {
		p += strcspn(p, "\"\\$");

		if (p[0] == '\0')
			break;

		len++;
		p++;
	}

	out = xmalloc(len);
	out[0] = '\0';

	strcat(out, "\"");

	p = in;
	while (1) {
		len = strcspn(p, "\"\\$");
		strncat(out, p, len);
		p += len;

		if (p[0] == '\0')
			break;

		strcat(out, "\\");
		strncat(out, p++, 1);
	}

	strcat(out, "\"");

	return out;
}

static void usage(const char *progname, FILE *out)
{
	fprintf(out, "Usage: %s <kconfig-file>\n", progname);
	fprintf(out, "Environment variables:\n");
	fprintf(out, "  KCONFIG_CONFIG=<config-file>\n");
	fprintf(out, "  CONF2NIX_OUTPUT_N=[none|unset|no]\n");
	fprintf(out, "  CONF2NIX_WARN_UNUSED=[0|1]\n");
	fprintf(out, "  CONF2NIX_WITH_PROMPT=[0|1]\n");
	fprintf(out, "  CONF2NIX_OUTPUT_EMPTY_STRING=[0|1]\n");
}

static bool parse_bool_env(const char *progname, const char *env_name,
			   bool default_value)
{
	const char *env;

	env = getenv(env_name);
	if (env) {
		if (!strcasecmp(env, "1"))
			return true;
		else if (!strcasecmp(env, "0"))
			return false;
		else {
			fprintf(stderr, "%s: failed to parse %s: '%s'\n",
				progname, env_name, env);
			fprintf(stderr, "  [0|1] required");
		}
	}
	return default_value;
}

int main(int argc, char **argv)
{
	int retval;
	const char *output_n_env;
	struct options options;
	enum output_n output_n = OUTPUT_N_NONE;
	bool ignore_invisible;
	bool warn_unused;
	bool with_prompt;
	bool output_empty_string;

	if (argc != 2) {
		fprintf(stderr, "%s: Kconfig file missing\n", argv[0]);
		usage(argv[0], stderr);
		exit(1);
	}

	output_n_env = getenv("CONF2NIX_OUTPUT_N");
	if (output_n_env) {
		if (!strcasecmp(output_n_env, "none"))
			output_n = OUTPUT_N_NONE;
		else if (!strcasecmp(output_n_env, "unset"))
			output_n = OUTPUT_N_AS_UNSET;
		else if (!strcasecmp(output_n_env, "no"))
			output_n = OUTPUT_N;
		else {
			fprintf(stderr,
				"%s: failed to parse CONF2NIX_OUTPUT_N: '%s'\n",
				argv[0], output_n_env);
			fprintf(stderr, "  [none|unset|no] required");
		}
	}
	ignore_invisible =
		parse_bool_env(argv[0], "CONF2NIX_IGNORE_INVISIBLE", true);
	warn_unused = parse_bool_env(argv[0], "CONF2NIX_WARN_UNUSED", true);
	with_prompt = parse_bool_env(argv[0], "CONF2NIX_WITH_PROMPT", false);
	output_empty_string =
		parse_bool_env(argv[0], "CONF2NIX_OUTPUT_EMPTY_STRING", false);
	options =
		(struct options){ .output_n = output_n,
				  .ignore_invisible = ignore_invisible,
				  .warn_unused = warn_unused,
				  .with_prompt = with_prompt,
				  .output_empty_string = output_empty_string };

	conf_parse(argv[1]);
	retval = conf_read(NULL);
	if (retval != 0) {
		fprintf(stderr, "%s: failed to read config file\n", argv[0]);
	}

	conf2nix(&options);

	return 0;
}
