// SPDX-License-Identifier: GPL-2.0-only

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lkc.h"

#define CONF2NIX_INDENT "  "

// the same as confdata.c
enum output_n { OUTPUT_N, OUTPUT_N_AS_UNSET, OUTPUT_N_NONE };

static void conf2nix(enum output_n output_n, bool warn_unused);
static void conf2nix_rec(struct menu *menu, enum output_n output_n);
static void conf2nix_heading(void);
static void conf2nix_footing(void);
static void conf2nix_footing(void);
static void conf2nix_symbol(struct symbol *sym, enum output_n output_n);
static void usage(const char *progname);
static char *escape_string_value(const char *in);

static void conf2nix(enum output_n output_n, bool warn_unused)
{
	int i;
	struct symbol *sym;

	conf2nix_heading();
	conf2nix_rec(&rootmenu, output_n);
	for_all_symbols(i, sym)
	{
		if (warn_unused && sym->name && sym->flags & SYMBOL_DEF_USER &&
		    !(sym->flags & SYMBOL_WRITTEN)) {
			fprintf(stderr, "unused symbol: '%s'\n", sym->name);
		}
		sym->flags &= ~SYMBOL_WRITTEN;
	};
	conf2nix_footing();
}

static void conf2nix_rec(struct menu *menu, enum output_n output_n)
{
	struct symbol *sym;
	struct menu *child;

	if (!menu_has_prompt(menu)) {
		// menu without prompt can not be set by nixpkgs
		goto conf_childs;
	}
	sym = menu->sym;
	if (!sym)
		goto conf_childs;

	sym_calc_value(sym);

	/* skip already written symbols */
	if (sym->flags & SYMBOL_WRITTEN)
		goto conf_childs;

	sym->flags |= SYMBOL_WRITTEN;
	conf2nix_symbol(sym, output_n);

conf_childs:
	for (child = menu->list; child; child = child->next)
		conf2nix_rec(child, output_n);
}

static void conf2nix_heading(void)
{
	printf("{ lib }:\n");
	printf("let\n");
	printf("  inherit (lib.kernel) yes no module freeform;\n");
	printf("in {\n");
}

static void conf2nix_footing(void)
{
	printf("}\n");
}

static void conf2nix_symbol(struct symbol *sym, enum output_n output_n)
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
		if (output_n != OUTPUT_N && tri == no) {
			if (output_n == OUTPUT_N_AS_UNSET)
				printf(CONF2NIX_INDENT "# \"%s\" is not set\n",
				       sym->name);
			break;
		}
		printf(CONF2NIX_INDENT "\"%s\" = ", sym->name);
		switch (tri) {
		case no:
			printf("no");
			break;
		case mod:
			printf("module");
			break;
		case yes:
			printf("yes");
			break;
		default: // unreachable
		}
		printf(";\n");
		break;
	// all other types are treated as string
	// including S_STRING, S_HEX, and S_INT
	case S_STRING:
	case S_HEX:
	case S_INT:
		val = value->val;
#if defined(CONF2NIX_EMPTY_STRING_WORKAROUND)
		// this is a workaround for nixpkgs
		// the config system of nixpkgs does not handle `freefrom ""` properly
		if (*val == '\0') {
			break;
		}
#endif
		escaped = escape_string_value(val);
		printf(CONF2NIX_INDENT "\"%s\" = ", sym->name);
		printf("freeform %s", escaped);
		printf(";\n");
	default: // unreachable
	}

	free(escaped);
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

static void usage(const char *progname)
{
	printf("Usage: %s <kconfig-file>\n", progname);
	printf("Environment variables:\n");
	printf("  KCONFIG_CONFIG=<config-file>\n");
	printf("  CONF2NIX_OUTPUT_N=[none|unset|no]\n");
}

int main(int argc, char **argv)
{
	int retval;
	const char *output_n_env;
	const char *warn_unused_env;
	enum output_n output_n = OUTPUT_N_NONE;
	bool warn_unused = true;

	if (argc != 2) {
		fprintf(stderr, "%s: Kconfig file missing\n", argv[0]);
		usage(argv[0]);
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
				"%s: failed to parse CONF2NIX_OUTPUT_N: '%s'",
				argv[0], output_n_env);
			fprintf(stderr, "  [none|unset|no] required");
		}
	}

	warn_unused_env = getenv("CONF2NIX_WARN_UNUSED");
	if (warn_unused_env) {
		if (!strcasecmp(warn_unused_env, "1"))
			warn_unused = true;
		else if (!strcasecmp(warn_unused_env, "0"))
			warn_unused = false;
		else {
			fprintf(stderr,
				"%s: failed to parse CONF2NIX_WARN_UNUSED: '%s'",
				argv[0], warn_unused_env);
			fprintf(stderr, "  [0|1] required");
		}
	}

	conf_parse(argv[1]);
	retval = conf_read(NULL);
	if (retval != 0) {
		fprintf(stderr, "%s: failed to read config file\n", argv[0]);
	}

	conf2nix(output_n, warn_unused);

	return 0;
}
