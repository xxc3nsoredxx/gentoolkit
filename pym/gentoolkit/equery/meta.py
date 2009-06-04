# Copyright(c) 2009, Gentoo Foundation
#
# Licensed under the GNU General Public License, v2 or higher
#
# $Header: $

"""Display metadata about a given package"""

# Move to Imports section after Python-2.6 is stable
from __future__ import with_statement

__author__  = "Douglas Anderson"
__docformat__ = 'epytext'

# =======
# Imports
# =======

import os
import re 
import sys
import xml.etree.cElementTree as ET
from getopt import gnu_getopt, GetoptError

from portage import settings

import gentoolkit.pprinter as pp
from gentoolkit import errors
from gentoolkit.equery import format_options, mod_usage, Config
from gentoolkit.helpers2 import find_packages, print_sequence, print_file, \
	uniqify
from gentoolkit.textwrap_ import TextWrapper

# =======
# Globals
# =======

# E1101: Module 'portage.output' has no $color member
# portage.output creates color functions dynamically
# pylint: disable-msg=E1101

QUERY_OPTS = {
	"current": False,
	"description": False,
	"herd": False,
	"maintainer": False,
	"useflags": False,
	"upstream": False,
	"xml": False
} 

# Get the location of the main Portage tree
PORTDIR = [settings["PORTDIR"] or os.path.join(os.sep, "usr", "portage")]
# Check for overlays
if settings["PORTDIR_OVERLAY"]:
	PORTDIR.extend(settings["PORTDIR_OVERLAY"].split())

# =========
# Functions
# =========

def print_help(with_description=True):
	"""Print description, usage and a detailed help message.
	
	@type with_description: bool
	@param with_description: if true, print module's __doc__ string
	"""

	if with_description:
		print __doc__.strip()
		print
	print mod_usage(mod_name="meta")
	print
	print pp.command("options")
	print format_options((
		(" -h, --help", "display this help message"),
		(" -c, --current", "parse metadata.xml in the current directory"),
		(" -d, --description", "show an extended package description"),
		(" -H, --herd", "show the herd(s) for the package"),
		(" -m, --maintainer", "show the maintainer(s) for the package"),
		(" -u, --useflags", "show per-package USE flag descriptions"),
		(" -U, --upstream", "show package's upstream information"),
		(" -x, --xml", "show the plain XML file")
	))


def call_get_functions(metadata_path, package_dir, QUERY_OPTS):
	"""Call information gathering functions and display the results."""
	
	if Config['verbose']:
		print get_overlay_name(package_dir)

	try:
		xml_tree = ET.parse(metadata_path)
	except IOError:
		pp.print_error("No metadata available")
		first_run = False
		return

	got_opts = False
	if (QUERY_OPTS["herd"] or QUERY_OPTS["description"] or
		QUERY_OPTS["useflags"] or QUERY_OPTS["maintainer"] or
		QUERY_OPTS["upstream"] or QUERY_OPTS["xml"]):
		# Specific information requested, less formatting
		got_opts = True

	if QUERY_OPTS["herd"] or not got_opts:
		herd = get_herd(xml_tree)
		if QUERY_OPTS["herd"]:
			herd = format_list(herd)
		else:
			herd = format_list(herd, "Herd:        ", " " * 13)
		print_sequence(herd)

	if QUERY_OPTS["maintainer"] or not got_opts:
		maint = get_maitainer(xml_tree)
		if QUERY_OPTS["maintainer"]:
			maint = format_list(maint)
		else:
			maint = format_list(maint, "Maintainer:  ", " " * 13)
		print_sequence(maint)

	if QUERY_OPTS["upstream"] or not got_opts:
		upstream = get_upstream(xml_tree)
		if QUERY_OPTS["upstream"]:
			upstream = format_list(upstream)
		else:
			upstream = format_list(upstream, "Upstream:    ", " " * 13)
		print_sequence(upstream)

	if QUERY_OPTS["description"]:
		desc = get_description(xml_tree)
		print_sequence(format_list(desc))

	if QUERY_OPTS["useflags"]:
		useflags = get_useflags(xml_tree)
		print_sequence(format_list(useflags))

	if QUERY_OPTS["xml"]:
		print_file(metadata_path)


def format_line(line, first="", subsequent="", force_quiet=False):
	"""Wrap a string at word boundaries and optionally indent the first line
	and/or subsequent lines with custom strings.

	Preserve newlines if the longest line is not longer than 
	Config['termWidth']. To force the preservation of newlines and indents, 
	split the string into a list and feed it to format_line via format_list.

	@see: format_list()
	@type line: string
	@param line: text to format
	@type first: string
	@param first: text to prepend to the first line
	@type subsequent: string
	@param subsequent: text to prepend to subsequent lines
	@type force_quiet: boolean
	@rtype: string
	@return: A wrapped line
	"""

	if line:
		line = line.expandtabs().strip("\n").splitlines() 
	else:
		if force_quiet:
			return
		else:
			return first + "None specified"

	if len(first) > len(subsequent):
		wider_indent = first
	else:
		wider_indent = subsequent
	
	widest_line_len = len(max(line, key=len)) + len(wider_indent)
	
	if widest_line_len > Config['termWidth']:
		twrap = TextWrapper(width=Config['termWidth'], expand_tabs=False,
			initial_indent=first, subsequent_indent=subsequent)
		line = " ".join(line)
		line = re.sub("\s+", " ", line)
		line = line.lstrip()
		result = twrap.fill(line)
	else:
		# line will fit inside Config['termWidth'], so preserve whitespace and 
		# newlines
		line[0] = first + line[0]          # Avoid two newlines if len == 1

		if len(line) > 1:
			line[0] = line[0] + "\n"
			for i in range(1, (len(line[1:-1]) + 1)):
				line[i] = subsequent + line[i] + "\n"
			line[-1] = subsequent + line[-1]  # Avoid two newlines on last line

		if line[-1].isspace():
			del line[-1]                # Avoid trailing blank lines

		result = "".join(line)

	return result.encode("utf-8")


def format_list(lst, first="", subsequent="", force_quiet=False):
	"""Feed elements of a list to format_line().

	@see: format_line()
	@type lst: list
	@param lst: list to format
	@type first: string
	@param first: text to prepend to the first line
	@type subsequent: string
	@param subsequent: text to prepend to subsequent lines
	@rtype: list
	@return: list with element text wrapped at Config['termWidth']
	"""

	result = []
	if lst:
		# Format the first line
		line = format_line(lst[0], first, subsequent, force_quiet)
		result.append(line)
		# Format subsequent lines
		for elem in lst[1:]:
			if elem:
				result.append(format_line(elem, subsequent, subsequent,
					force_quiet))
			else:
				# We don't want to send a blank line to format_line()
				result.append("")
	else:
		if Config['verbose']:
			if force_quiet:
				result = None
			else:
				# Send empty list, we'll get back first + `None specified'
				result.append(format_line(lst, first, subsequent))

	return result


def get_herd(xml_tree):
	"""Return a list of text nodes for <herd>."""
	
	result = []
	for elem in xml_tree.findall("herd"):
		herd_mail = get_herd_email(elem.text)
		if herd_mail and Config['verbose']:
			result.append("%s (%s)" % (elem.text, herd_mail))
		else:
			result.append(elem.text) 

	return result


def get_herd_email(herd):
	"""Return the email of the given herd if it's in herds.xml, else None."""
	
	herds_path = os.path.join(PORTDIR[0], "metadata/herds.xml")

	try:
		herds_tree = ET.parse(herds_path)
	except IOError, err:
		pp.print_error(str(err))
		return None

	# Some special herds are not listed in herds.xml
	if herd in ('no-herd', 'maintainer-wanted', 'maintainer-needed'):
		return None
	
	for node in herds_tree.getiterator("herd"):
		if node.findtext("name") == herd:
			return node.findtext("email")


def get_description(xml_tree):
	"""Return a list of text nodes for <longdescription>.

	@todo: Support the `lang' attribute
	"""

	return [e.text for e in xml_tree.findall("longdescription")]


def get_maitainer(xml_tree):
	"""Return a parsable tree of all maintainer elements and sub-elements."""

	first_run = True
	result = []
	for node in xml_tree.findall("maintainer"):
		if not first_run:
			result.append("")
		restrict = node.get("restrict")
		if restrict:
			result.append("(%s %s)" %
			(pp.emph("Restrict to"), pp.output.green(restrict)))
		result.extend(e.text for e in node)
		first_run = False

	return result


def get_overlay_name(p_dir):
	"""Determine the overlay name and return a formatted string."""

	result = []
	cat_pkg = '/'.join(p_dir.split('/')[-2:])
	result.append(" * %s" % pp.cpv(cat_pkg))
	o_dir = '/'.join(p_dir.split('/')[:-2])
	if o_dir != PORTDIR[0]:
		# o_dir is an overlay
		o_name = o_dir.split('/')[-1]
		o_name = ("[", o_name, "]")
		result.append(pp.output.turquoise("".join(o_name)))

	return ' '.join(result)


def get_package_directory(query):
	"""Find a package's portage directory."""

	matches = find_packages(query, include_masked=True)
	# Prefer a package that's in the Portage tree over one in an
	# overlay. Start with oldest first.
	pkg = None
	while list(reversed(matches)):
		pkg = matches.pop()
		if not pkg.is_overlay():
			break
	
	return pkg.get_package_path() if pkg else None
	

def get_useflags(xml_tree):
	"""Return a list of formatted <useflag> lines, including blank elements
	where blank lines should be printed."""

	first_run = True
	result = []
	for node in xml_tree.getiterator("flag"):
		if not first_run:
			result.append("")
		flagline = pp.useflag(node.get("name"))
		restrict = node.get("restrict")
		if restrict:
			result.append("%s (%s %s)" %
				(flagline, pp.emph("Restrict to"), pp.output.green(restrict)))
		else:
			result.append(flagline)
		# ElementTree handles nested element text in a funky way. 
		# So we need to dump the raw XML and parse it manually.
		flagxml = ET.tostring(node)
		flagxml = re.sub("\s+", " ", flagxml)
		flagxml = re.sub("\n\t", "", flagxml)
		flagxml = re.sub("<(pkg|cat)>(.*?)</(pkg|cat)>",
			pp.cpv(r"\2"), flagxml)
		flagtext = re.sub("<.*?>", "", flagxml)
		result.append(flagtext)
		first_run = False

	return result


def _get_upstream_bugtracker(node):
	"""Extract and format upstream bugtracker information."""

	bt_loc = [e.text for e in node.findall("bugs-to")]

	return format_list(bt_loc, "Bugs to:    ", " " * 12, force_quiet=True)


def _get_upstream_changelog(node):
	"""Extract and format upstream changelog information."""

	cl_paths = [e.text for e in node.findall("changelog")]

	return format_list(cl_paths, "Changelog:  ", " " * 12, force_quiet=True)


def _get_upstream_documentation(node):
	"""Extract and format upstream documentation information."""

	doc = []
	for elem in node.findall("doc"):
		lang = elem.get("lang")
		if lang:
			lang = "(%s)" % pp.output.yellow(lang)
		else:
			lang = ""
		doc.append(" ".join([elem.text, lang]))

	return format_list(doc, "Docs:       ", " " * 12, force_quiet=True)


def _get_upstream_maintainer(node):
	"""Extract and format upstream maintainer information."""

	maintainer = node.findall("maintainer")
	maint = []
	for elem in maintainer:
		if elem.find("name") != None:
			maint.append(elem.find("name").text)
		if elem.find("email") != None:
			maint.append(elem.find("email").text)
		if elem.get("status") == "active":
			maint.append("(%s)" % pp.output.green("active"))
		elif elem.get("status") == "inactive":
			maint.append("(%s)" % pp.output.red("inactive"))
		elif elem.get("status") != None:
			maint.append("(" + elem.get("status") + ")")

	return format_list(maint, "Maintainer: ", " " * 12, force_quiet=True)


def _get_upstream_remoteid(node):
	"""Extract and format upstream remote ID."""

	r_id = [e.get("type") + ": " + e.text for e in node.findall("remote-id")]

	return format_list(r_id, "Remote ID:  ", " " * 12, force_quiet=True)


def get_upstream(xml_tree):
	"""Return a list of formatted <upstream> lines, including blank elements
	where blank lines should be printed."""

	first_run = True
	result = []
	for node in xml_tree.findall("upstream"):
		if not first_run:
			result.append("")

		maint = _get_upstream_maintainer(node)
		if maint:
			result.append("\n".join(maint))

		changelog = _get_upstream_changelog(node)
		if changelog:
			result.append("\n".join(changelog))

		documentation = _get_upstream_documentation(node)
		if documentation:
			result.append("\n".join(documentation))

		bugs_to = _get_upstream_bugtracker(node)
		if bugs_to:
			result.append("\n".join(bugs_to))

		remote_id = _get_upstream_remoteid(node)
		if remote_id:
			result.append("\n".join(remote_id))

		first_run = False

	return result


def parse_module_options(module_opts):
	"""Parse module options and update GLOBAL_OPTS"""

	opts = (x[0] for x in module_opts)
	for opt in opts:
		if opt in ('-h', '--help'):
			print_help()
			sys.exit(0)
		elif opt in ('-c', '--current'):
			QUERY_OPTS["current"] = True
		elif opt in ('-d', '--description'):
			QUERY_OPTS["description"] = True
		elif opt in ('-H', '--herd'):
			QUERY_OPTS["herd"] = True
		elif opt in ('-m', '--maintainer'):
			QUERY_OPTS["maintainer"] = True
		elif opt in ('-u', '--useflags'):
			QUERY_OPTS["useflags"] = True
		elif opt in ('-U', '--upstream'):
			QUERY_OPTS["upstream"] = True
		elif opt in ('-x', '--xml'):
			QUERY_OPTS["xml"] = True


def main(input_args):
	"""Parse input and run the program."""

	short_opts = "hcdHmuUx"
	long_opts = ('help', 'current', 'description', 'herd', 'maintainer',
		'useflags', 'upstream', 'xml')

	try:
		module_opts, queries = gnu_getopt(input_args, short_opts, long_opts)
	except GetoptError, err:
		pp.print_error("Module %s" % err)
		print
		print_help(with_description=False)
		sys.exit(2)

	parse_module_options(module_opts)
	
	# Find queries' Portage directory and throw error if invalid
	if not queries and not QUERY_OPTS["current"]:
		print_help()
		sys.exit(2)
	
	if QUERY_OPTS["current"]:
		package_dir = os.getcwd()
		metadata_path = os.path.join(package_dir, "metadata.xml")
		call_get_functions(metadata_path, package_dir, QUERY_OPTS)
	else:
		first_run = True
		for query in queries:
			package_dir = get_package_directory(query)
			if not package_dir:
				raise errors.GentoolkitNoMatches(query)
			metadata_path = os.path.join(package_dir, "metadata.xml")

			# --------------------------------
			# Check options and call functions
			# --------------------------------
		
			if not first_run:
				print
				
			call_get_functions(metadata_path, package_dir, QUERY_OPTS)
	
			first_run = False
