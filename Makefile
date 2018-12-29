# Makefile for WebParser as a TRIPS component

NAME = WebParser
DEFSYS = defsys.lisp
SYSTEM = :webparser

CONFIGDIR=../config
include $(CONFIGDIR)/lisp/lib.mk
include $(CONFIGDIR)/Graphviz/defs.mk

WWW_DIR = $(prefix)/www
CGI_DIR = $(WWW_DIR)/cgi
STYLE_DIR = $(WWW_DIR)/style
ETC_STYLE_DIR = $(etcdir)/style

CGI_FILES = dot-htaccess cgi-kqml-bridge.pl ../KQML/KQML.pm dot-to-svg.pl
STYLE_FILES = word-def.xsl drum-interface.xsl parser-interface.xsl parser-interface.js parser-interface.css tree-to-lisp.xsl tree-to-LinGO.xsl tree-to-dot.xsl lf-to-html.xsl lf-to-amr.xsl lf-to-dot.xsl tags-to-table.xsl exts-to-table.xsl exts-to-rdf.xsl ekb-to-dot.xsl exslt/str.replace.template.xsl exslt/str.tokenize.template.xsl
OTHER_WWW_FILES = trips-parser-output.dtd ../Parser/docs/LF\ Documentation.pdf api.html

install:: $(CGI_FILES) $(STYLE_FILES) $(OTHER_WWW_FILES)
	echo "HELLOOOOOOOOO"
	echo $(WWW_DIR)
	echo "HELLOOOOOOOOO"
	$(MKINSTALLDIRS) $(WWW_DIR) $(CGI_DIR) $(STYLE_DIR)
	$(INSTALL_PROGRAM) $(CGI_FILES) $(CGI_DIR)
	mv $(CGI_DIR)/dot-htaccess $(CGI_DIR)/.htaccess
	rm -f $(CGI_DIR)/cgi-kqml-bridge.pl
	./install-cgi.pl $(CGI_DIR) parse
	./install-cgi.pl $(CGI_DIR) get-word-def
	for d in ../Systems/* ; do \
	  if [ -d $$d -a $$d != "../Systems/core" -a $$d != "../Systems/CVS" ] ; then \
	    ./install-cgi.pl $(CGI_DIR) `basename $$d` || exit 1 ; \
	  fi ; \
	done
	$(INSTALL_DATA) $(STYLE_FILES) $(STYLE_DIR)
	$(INSTALL_DATA) $(OTHER_WWW_FILES) $(WWW_DIR)

# some style files may be installed independently of the others, as they can be
# useful for other purposes; these are installed in ($etcdir)/style/.
EKB_STYLE_FILES = ekb-to-dot.xsl exts-to-rdf.xsl lf-to-dot.xsl exslt/str.replace.template.xsl
install-ekb-style: ${EKB_STYLE_FILES}
	$(MKINSTALLDIRS) $(ETC_STYLE_DIR)
	$(INSTALL_DATA) $(EKB_STYLE_FILES) $(ETC_STYLE_DIR)

dot-htaccess:
	( case `hostname` in \
	    b01.cs.rochester.edu) ;; \
	    *) echo 'Options ExecCGI' ;; \
	  esac ; \
	  echo 'SetHandler cgi-script' \
	) >$@

dot-to-svg.pl: dot-to-svg.pl.in
	sed -e 's@DOT_LIB_DIR@$(DOT_LIB_DIR)@g' \
	    -e 's@DOT_BIN_DIR@$(DOT_BIN_DIR)@g' \
	    -e 's@DOT_TO_SVG_CMD@|ccomps -x |dot |gvpack -array1 |neato -Tsvg -n2@g' \
	    $< >$@

trips-parser-output.dtd: make-dtd.lisp
	case "$(LISP_FLAVOR)" in \
	  cmucl) \
	    $(LISPCMD) -load make-dtd.lisp -eval '(make-dtd)' -eval '(quit)' \
	    ;; \
	  sbcl|abcl) \
	    $(LISPCMD) --load make-dtd.lisp --eval '(make-dtd)' --eval '(quit)' \
	    ;; \
	  ccl|openmcl) \
	    $(LISPCMD) -l make-dtd.lisp -e '(make-dtd)' -e '(quit)' \
	    ;; \
	  allegro) \
	    $(LISPCMD) -L make-dtd.lisp -e '(make-dtd)' -e '(exit)' \
	    ;; \
	  clisp) \
	    $(LISPCMD) -i make-dtd.lisp -x '(make-dtd)' -x '(quit)' \
	    ;; \
	  *) \
	    echo "Unsupported lisp flavor '$(LISP_FLAVOR)'" \
	    exit 1 \
	    ;; \
	esac

clean::
	rm -f trips-parser-output.dtd dot-to-svg.pl

