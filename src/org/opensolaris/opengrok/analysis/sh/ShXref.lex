/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").  
 * You may not use this file except in compliance with the License.
 *
 * See LICENSE.txt included in this distribution for the specific
 * language governing permissions and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at LICENSE.txt.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Copyright (c) 2005, 2017, Oracle and/or its affiliates. All rights reserved.
 * Portions Copyright (c) 2017, Chris Fraire <cfraire@me.com>.
 */

package org.opensolaris.opengrok.analysis.sh;
import org.opensolaris.opengrok.analysis.JFlexXref;
import java.io.IOException;
import org.opensolaris.opengrok.web.Util;
import java.util.Stack;

%%
%public
%class ShXref
%extends JFlexXref
%unicode
%ignorecase
%int
%include CommonXref.lexh
%{
  private final Stack<Integer> stateStack = new Stack<Integer>();
  private final Stack<String> styleStack = new Stack<String>();

  // State variables for the HEREDOC state. They tell what the stop word is,
  // and whether leading tabs should be removed from the input lines before
  // comparing with the stop word.
  private String heredocStopWord;
  private boolean heredocStripLeadingTabs;

  @Override
  public void reInit(char[] contents, int length) {
    super.reInit(contents, length);
    stateStack.clear();
    styleStack.clear();
  }

  // TODO move this into an include file when bug #16053 is fixed
  @Override
  protected int getLineNumber() { return yyline; }
  @Override
  protected void setLineNumber(int x) { yyline = x; }

  private void pushstate(int state, String style) throws IOException {
    if (!styleStack.empty()) {
      out.write("</span>");
    }
    if (style == null) {
      out.write("<span>");
    } else {
      out.write("<span class=\"" + style + "\">");
    }
    stateStack.push(yystate());
    styleStack.push(style);
    yybegin(state);
  }

  private void popstate() throws IOException {
    out.write("</span>");
    yybegin(stateStack.pop());
    styleStack.pop();
    if (!styleStack.empty()) {
      String style = styleStack.peek();
      if (style == null) {
        out.write("<span>");
      } else {
        out.write("<span class=\"" + style + "\">");
      }
    }
  }

  /**
   * Check the contents of a line to see if it matches the stop word for a
   * here-document.
   *
   * @param line a line in the input file
   * @return true if the line terminates a here-document, false otherwise
   */
  private boolean isHeredocStopWord(String line) {
    // Skip leading tabs if heredocStripLeadingTabs is true.
    int i = 0;
    while (heredocStripLeadingTabs &&
              i < line.length() && line.charAt(i) == '\t') {
      i++;
    }

    // Compare remaining characters on the line with the stop word.
    return line.substring(i).equals(heredocStopWord);
  }

%}

Identifier = [a-zA-Z_] [a-zA-Z0-9_]+
Number = \$? [0-9]+\.[0-9]+|[0-9][0-9]*|"0x" [0-9a-fA-F]+

File = {FNameChar}+ "." ([a-zA-Z]+)

/*
 * States:
 * STRING - double-quoted string, ex: "hello, world!"
 * SCOMMENT - single-line comment, ex: # this is a comment
 * QSTRING - single-quoted string, ex: 'hello, world!'
 * SUBSHELL - commands executed in a sub-shell,
 *               example 1: (echo $header; cat file.txt)
 *               example 2 (command substitution): $(cat file.txt)
 * BACKQUOTE - command substitution using back-quotes, ex: `cat file.txt`
 * BRACEGROUP - group of commands in braces, possibly ksh command substitution
 *              extension, ex: ${ cat file.txt; }
 * HEREDOC - here-document, example: cat<<EOF ... EOF
 */
%state STRING SCOMMENT QSTRING SUBSHELL BACKQUOTE BRACEGROUP HEREDOC

%include Common.lexh
%include CommonURI.lexh
%include CommonPath.lexh
%include CommonLaxFPath.lexh
%%
<STRING>{
 "$" {Identifier} {
    String id = yytext();
    out.write("<a href=\"");
    out.write(urlPrefix);
    out.write("refs=");
    out.write(id);
    appendProject();
    out.write("\">");
    out.write(id);
    out.write("</a>");
 }

  /* This rule matches associative arrays inside strings,
     for instance "${array["string"]}". Push a new STRING
     state on the stack to prevent premature exit from the
     STRING state. */
  \$\{ {Identifier} \[\" {
    out.write(yytext()); pushstate(STRING, "s");
  }
}

<YYINITIAL, SUBSHELL, BACKQUOTE, BRACEGROUP> {
\$ ? {Identifier} {
    String id = yytext();
    writeSymbol(id, Consts.shkwd, yyline);
}

{Number}        { out.write("<span class=\"n\">"); out.write(yytext()); out.write("</span>"); }

 \$ ? \" { pushstate(STRING, "s"); out.write(yytext()); }
 \$ ? \' { pushstate(QSTRING, "s"); out.write(yytext()); }
 "#"     { pushstate(SCOMMENT, "c"); out.write(yytext()); }

 // Recognize here-documents. At least a subset of them.
 "<<" "-"? {WhspChar}* {Identifier} {WhspChar}* {
   String text = yytext();
   out.write(Util.htmlize(text));

   heredocStripLeadingTabs = (text.charAt(2) == '-');
   heredocStopWord = text.substring(heredocStripLeadingTabs ? 3 : 2).trim();
   pushstate(HEREDOC, "s");
 }

 // Any sequence of more than two < characters should not start HEREDOC. Use
 // this rule to catch them before the HEREDOC rule.
 "<<" "<" + {
   out.write(Util.htmlize(yytext()));
 }

}

<STRING> {
 \" {WhspChar}* \"  { out.write(yytext()); }
 \"     { out.write(yytext()); popstate(); }
 \\\\ | \\\" | \\\$ | \\` { out.write(yytext()); }
 \$\(   { pushstate(SUBSHELL, null); out.write(yytext()); }
 `      { pushstate(BACKQUOTE, null); out.write(yytext()); }

 /* Bug #15661: Recognize ksh command substitution within strings. According
  * to ksh man page http://www2.research.att.com/~gsf/man/man1/ksh-man.html#Command%20Substitution
  * the opening brace must be followed by a blank.
  */
 "${" / {WhspChar} | {EOL} {
   pushstate(BRACEGROUP, null); out.write(yytext());
 }
}

<QSTRING> {
 \' {WhspChar}* \' { out.write(yytext()); }
 \\'  { out.write("\\'"); }
 \'   { out.write(yytext()); popstate(); }
}

<SCOMMENT> {
{EOL} { popstate();
     startNewLine();}
}

<SUBSHELL> {
  \)   { out.write(yytext()); popstate(); }
}

<BACKQUOTE> {
  ` { out.write(yytext()); popstate(); }
}

<BRACEGROUP> {
 /* Bug #15661: Terminate a ksh brace group. According to ksh man page
  * http://www2.research.att.com/~gsf/man/man1/ksh-man.html#Command%20Substitution
  * the closing brace must be on beginning of line, or it must be preceded by
  * a semi-colon and (optionally) whitespace.
  */
  ^ {WhspChar}* \}  { out.write(yytext()); popstate(); }
  ; {WhspChar}* \}  { out.write(yytext()); popstate(); }
}

<HEREDOC> {
  [^\n]+ {
    String line = yytext();
    if (isHeredocStopWord(line)) {
      popstate();
    }
    out.write(Util.htmlize(line));
  }

  {EOL} { startNewLine(); }
}

<YYINITIAL, SUBSHELL, BACKQUOTE, BRACEGROUP> {
  /* Don't enter new state if special character is escaped. */
  \\` | \\\( | \\\) | \\\\ | \\\{ { out.write(yytext()); }
  \\\" | \\' | \\\$ | \\\# { out.write(yytext()); }

  /* $# should not start a comment. */
  "$#" { out.write(yytext()); }

  \$ ? \( { pushstate(SUBSHELL, null); out.write(yytext()); }
  ` { pushstate(BACKQUOTE, null); out.write(yytext()); }

 /* Bug #15661: Recognize ksh command substitution within strings. According
  * to ksh man page http://www2.research.att.com/~gsf/man/man1/ksh-man.html#Command%20Substitution
  * the opening brace must be followed by a blank. Make the initial dollar sign
  * optional so that we get the nesting right and don't terminate the brace
  * group too early if the ${ cmd; } expression contains nested { cmd; } groups.
  */
  \$ ? \{ / {WhspChar} | {EOL} {
    pushstate(BRACEGROUP, null); out.write(yytext());
  }
}

<YYINITIAL, SUBSHELL, BACKQUOTE, BRACEGROUP, STRING, SCOMMENT, QSTRING> {
{File} {
    String path = yytext();
    out.write("<a href=\""+urlPrefix+"path=");
    out.write(path);
    appendProject();
    out.write("\">");
    out.write(path);
    out.write("</a>");
}

{RelaxedMiddleFPath}
        { out.write(Util.breadcrumbPath(urlPrefix+"path=",yytext(),'/'));}
"&"     {out.write( "&amp;");}
"<"     {out.write( "&lt;");}
">"     {out.write( "&gt;");}
{WhiteSpace}{EOL} |
    {EOL}    { startNewLine(); }
{WhiteSpace}   { out.write(yytext()); }
[!-~]   { out.write(yycharat(0)); }
[^\n]      { writeUnicodeChar(yycharat(0)); }
}

<STRING, SCOMMENT, QSTRING> {

{BrowseableURI}    {
    appendLink(yytext(), true);
}

{FNameChar}+ "@" {FNameChar}+ "." {FNameChar}+
        {
          writeEMailAddress(yytext());
        }
}

<<EOF>> {
    // If we reach EOF while being in a nested state, pop all the way up
    // the initial state so that we close open HTML tags.
    while (!stateStack.isEmpty()) {
        popstate();
    }
    return YYEOF;
}
