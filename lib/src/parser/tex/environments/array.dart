// The MIT License (MIT)
//
// Copyright (c) 2013-2019 Khan Academy and other contributors
// Copyright (c) 2020 znjameswu <znjameswu@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'package:collection/collection.dart';
import 'package:flutter_math_fork/src/ast/nodes/stretchy_op.dart';

import '../../../ast/nodes/left_right.dart';
import '../../../ast/nodes/matrix.dart';
import '../../../ast/nodes/style.dart';
import '../../../ast/nodes/symbol.dart';
import '../../../ast/options.dart';
import '../../../ast/size.dart';
import '../../../ast/style.dart';
import '../../../ast/syntax_tree.dart';
import '../define_environment.dart';
import '../functions/katex_base.dart';
import '../macros.dart';
import '../parse_error.dart';
import '../parser.dart';

const arrayEntries = {
  [
    'array',
    'darray',
  ]: EnvSpec(
    numArgs: 1,
    handler: _arrayHandler,
  ),
  [
    'matrix',
    'pmatrix',
    'bmatrix',
    'Bmatrix',
    'vmatrix',
    'Vmatrix',
  ]: EnvSpec(
    numArgs: 0,
    handler: _matrixHandler,
  ),
  ['smallmatrix']: EnvSpec(numArgs: 0, handler: _smallMatrixHandler),
  ['subarray']: EnvSpec(numArgs: 1, handler: _subArrayHandler),
  ['CD']: EnvSpec(numArgs: 1, handler: _cdHandler),
};

enum ColSeparationType {
  align,
  alignat,
  small,
}

List<MatrixSeparatorStyle> getHLines(TexParser parser) {
  // Return an array. The array length = number of hlines.
  // Each element in the array tells if the line is dashed.
  final hlineInfo = <MatrixSeparatorStyle>[];
  parser.consumeSpaces();
  var next = parser.fetch().text;
  while (next == '\\hline' || next == '\\hdashline') {
    parser.consume();
    hlineInfo.add(next == '\\hdashline'
        ? MatrixSeparatorStyle.dashed
        : MatrixSeparatorStyle.solid);
    parser.consumeSpaces();
    next = parser.fetch().text;
  }
  return hlineInfo;
}

/// Parse the body of the environment, with rows delimited by \\ and
/// columns delimited by &, and create a nested list in row-major order
/// with one group per cell.  If given an optional argument style
/// ('text', 'display', etc.), then each cell is cast into that style.
MatrixNode parseArray(
  TexParser parser, {
  bool hskipBeforeAndAfter = false,
  double? arrayStretch,
  List<MatrixSeparatorStyle> separators = const [],
  List<MatrixColumnAlign> colAligns = const [],
  MathStyle? style,
  bool isSmall = false,
}) {
  // Parse body of array with \\ temporarily mapped to \cr
  parser.macroExpander.beginGroup();
  parser.macroExpander.macros.set('\\\\', MacroDefinition.fromString('\\cr'));

  // Get current arraystretch if it's not set by the environment
  if (arrayStretch == null) {
    final stretch = parser.macroExpander.expandMacroAsText('\\arraystretch');
    if (stretch == null) {
      // Default \arraystretch from lttab.dtx
      arrayStretch = 1.0;
    } else {
      arrayStretch = double.tryParse(stretch);
      if (arrayStretch == null || arrayStretch < 0) {
        throw ParseException('Invalid \\arraystretch: $stretch');
      }
    }
  }

  // Start group for first cell
  parser.macroExpander.beginGroup();

  var row = <EquationRowNode>[];
  final body = [row];
  final rowGaps = <Measurement>[];
  final hLinesBeforeRow = <MatrixSeparatorStyle>[];

  // Test for \hline at the top of the array.
  hLinesBeforeRow
      .add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);

  while (true) {
    // Parse each cell in its own group (namespace)
    final cellBody =
        parser.parseExpression(breakOnInfix: false, breakOnTokenText: '\\cr');
    parser.macroExpander.endGroup();
    parser.macroExpander.beginGroup();

    final cell = style == null
        ? cellBody.wrapWithEquationRow()
        : StyleNode(
            children: cellBody,
            optionsDiff: OptionsDiff(style: style),
          ).wrapWithEquationRow();
    row.add(cell);

    final next = parser.fetch().text;
    if (next == '&') {
      parser.consume();
    } else if (next == '\\end') {
      // Arrays terminate newlines with `\crcr` which consumes a `\cr` if
      // the last line is empty.
      // NOTE: Currently, `cell` is the last item added into `row`.
      if (row.length == 1 && cellBody.isEmpty) {
        body.removeLast();
      }
      if (hLinesBeforeRow.length < body.length + 1) {
        hLinesBeforeRow.add(MatrixSeparatorStyle.none);
      }
      break;
    } else if (next == '\\cr') {
      final cr = assertNodeType<CrNode>(parser.parseFunction(null, null, null));
      rowGaps.add(cr.size ?? Measurement.zero);

      // check for \hline(s) following the row separator
      hLinesBeforeRow
          .add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);

      row = [];
      body.add(row);
    } else {
      throw ParseException(
          'Expected & or \\\\ or \\cr or \\end', parser.nextToken);
    }
  }

  // End cell group
  parser.macroExpander.endGroup();
  // End array group defining \\
  parser.macroExpander.endGroup();

  return MatrixNode(
    body: body,
    vLines: separators,
    columnAligns: colAligns,
    rowSpacings: rowGaps,
    arrayStretch: arrayStretch,
    hLines: hLinesBeforeRow,
    hskipBeforeAndAfter: hskipBeforeAndAfter,
    isSmall: isSmall,
  );
}

/// Decides on a style for cells in an array according to whether the given
/// environment name starts with the letter 'd'.
MathStyle _dCellStyle(String envName) =>
    envName.substring(0, 1) == 'd' ? MathStyle.display : MathStyle.text;

// const _alignMap = {
//   'c': 'center',
//   'l': 'left',
//   'r': 'right',
// };

// class ColumnConf {
//   final List<String> separators;
//   final List<_AlignSpec> aligns;
//   // final bool hskipBeforeAndAfter;
//   // final double arrayStretch;
//   ColumnConf({
//     required this.separators,
//     required this.aligns,
//     // this.hskipBeforeAndAfter = false,
//     // this.arrayStretch = 1,
//   });
// }

GreenNode _arrayHandler(TexParser parser, EnvContext context) {
  final symArg = parser.parseArgNode(mode: null, optional: false);
  final colalign = symArg is SymbolNode
      ? [symArg]
      : assertNodeType<EquationRowNode>(symArg).children;
  final separators = <MatrixSeparatorStyle>[];
  final aligns = <MatrixColumnAlign>[];
  var alignSpecified = true;
  var lastIsSeparator = false;

  for (final nde in colalign) {
    final node = assertNodeType<SymbolNode>(nde);
    final ca = node.symbol;
    switch (ca) {
      //ignore_for_file: switch_case_completes_normally
      case 'l':
      case 'c':
      case 'r':
        aligns.add(const {
          'l': MatrixColumnAlign.left,
          'c': MatrixColumnAlign.center,
          'r': MatrixColumnAlign.right,
        }[ca]!);
        if (alignSpecified) {
          separators.add(MatrixSeparatorStyle.none);
        }
        alignSpecified = true;
        lastIsSeparator = false;
        break;
      case '|':
      case ':':
        if (alignSpecified) {
          separators.add(const {
            '|': MatrixSeparatorStyle.solid,
            ':': MatrixSeparatorStyle.dashed,
          }[ca]!);
          // aligns.add(MatrixColumnAlign.center);
        }
        alignSpecified = false;
        lastIsSeparator = true;
        break;
      default:
        throw ParseException('Unknown column alignment: $ca');
    }
  }
  if (!lastIsSeparator) {
    separators.add(MatrixSeparatorStyle.none);
  }
  return parseArray(
    parser,
    separators: separators,
    colAligns: aligns,
    hskipBeforeAndAfter: true,
    style: _dCellStyle(context.envName),
  );
}

GreenNode _matrixHandler(TexParser parser, EnvContext context) {
  final delimiters = const {
    'matrix': null,
    'pmatrix': ['(', ')'],
    'bmatrix': ['[', ']'],
    'Bmatrix': ['{', '}'],
    'vmatrix': ['|', '|'],
    'Vmatrix': ['\u2223', '\u2223'],
  }[context.envName];
  final res = parseArray(
    parser,
    hskipBeforeAndAfter: false,
    style: _dCellStyle(context.envName),
  );
  return delimiters == null
      ? res
      : LeftRightNode(
          leftDelim: delimiters[0],
          rightDelim: delimiters[1],
          body: [
            [res].wrapWithEquationRow()
          ],
        );
}

GreenNode _smallMatrixHandler(TexParser parser, EnvContext context) =>
    parseArray(
      parser,
      arrayStretch: 0.5,
      style: MathStyle.script,
      isSmall: true,
    );

GreenNode _subArrayHandler(TexParser parser, EnvContext context) {
  // Parsing of {subarray} is similar to {array}
  final symArg = parser.parseArgNode(mode: null, optional: false);
  final colalign = symArg is SymbolNode
      ? [symArg]
      : assertNodeType<EquationRowNode>(symArg).children;
  // final separators = <MatrixSeparatorStyle>[];
  final aligns = <MatrixColumnAlign>[];
  for (final nde in colalign) {
    final node = assertNodeType<SymbolNode>(nde);
    final ca = node.symbol;
    if (ca == 'l' || ca == 'c') {
      aligns.add(ca == 'l' ? MatrixColumnAlign.left : MatrixColumnAlign.center);
    } else {
      throw ParseException('Unknown column alignment: $ca');
    }
  }
  if (aligns.length > 1) {
    throw ParseException('{subarray} can contain only one column');
  }
  final res = parseArray(
    parser,
    colAligns: aligns,
    hskipBeforeAndAfter: false,
    arrayStretch: 0.5,
    style: MathStyle.script,
  );
  if (res.body[0].length > 1) {
    throw ParseException('{subarray} can contain only one column');
  }
  return res;
}

bool isStartOfArrow(GreenNode node) {
  return (node is SymbolNode && node.symbol == "@");
}

GreenNode _cdHandler(TexParser parser, EnvContext context) {
  parser.macroExpander.beginGroup();
  parser.macroExpander.macros
      .set("\\cr", MacroDefinition.fromString("\\\\\\relax"));
  parser.macroExpander.beginGroup();
  var parsedRows = <List<GreenNode>>[];
  while (true) {
    // eslint-disable-line no-constant-condition
    // Get the parse nodes for the next row.
    parsedRows.add(
        parser.parseExpression(breakOnInfix: false, breakOnTokenText: "\\\\"));
    parser.macroExpander.endGroup();
    parser.macroExpander.beginGroup();
    var next = parser.fetch().text;
    if (next == "&" || next == "\\\\") {
      parser.consume();
    } else if (next == "\\end") {
      if (parsedRows[parsedRows.length - 1].length == 0) {
        parsedRows.removeLast(); // final row ended in \\
      }
      break;
    } else {
      throw ParseException("Expected \\\\ or \\cr or \\end", parser.nextToken);
    }
  }

  var row = <EquationRowNode>[];
  final body = [row];

  // Loop thru the parse nodes. Collect them into cells and arrows.
  for (int i = 0; i < parsedRows.length; i++) {
    // Start a new row.
    var rowNodes = parsedRows[i];
    // Create the first cell.
    var cell = EquationRowNode(children: []);

    for (int j = 0; j < rowNodes.length; j++) {
      if (!isStartOfArrow(rowNodes[j])) {
        // If a parseNode is not an arrow, it goes into a cell.
        cell.children.add(rowNodes[j]);
      } else {
        // Parse node j is an "@", the start of an arrow.
        // Before starting on the arrow, push the cell into `row`.
        row.add(cell);

        // Now collect parseNodes into an arrow.
        // The character after "@" defines the arrow type.
        j += 1;
        var arrowChar = (rowNodes[j] as SymbolNode).symbol;

        // Create two empty label nodes. We may or may not use them.
        /*
                const labels: ParseNode<"ordgroup">[] = new Array(2);
                labels[0] = {type: "ordgroup", mode: "math", body: []};
                labels[1] = {type: "ordgroup", mode: "math", body: []};

                // Process the arrow.
                if ("=|.".indexOf(arrowChar) > -1) {
                    // Three "arrows", ``@=`, `@|`, and `@.`, do not take labels.
                    // Do nothing here.
                } else if ("<>AV".indexOf(arrowChar) > -1) {
                    // Four arrows, `@>>>`, `@<<<`, `@AAA`, and `@VVV`, each take
                    // two optional labels. E.g. the right-point arrow syntax is
                    // really:  @>{optional label}>{optional label}>
                    // Collect parseNodes into labels.
                    for (let labelNum = 0; labelNum < 2; labelNum++) {
                        let inLabel = true;
                        for (let k = j + 1; k < rowNodes.length; k++) {
                            if (isLabelEnd(rowNodes[k], arrowChar)) {
                                inLabel = false;
                                j = k;
                                break;
                            }
                            if (isStartOfArrow(rowNodes[k])) {
                                throw new ParseError("Missing a " + arrowChar +
                                " character to complete a CD arrow.", rowNodes[k]);
                            }

                            labels[labelNum].body.push(rowNodes[k]);
                        }
                        if (inLabel) {
                            // isLabelEnd never returned a true.
                            throw new ParseError("Missing a " + arrowChar +
                                " character to complete a CD arrow.", rowNodes[j]);
                        }
                    }
                } else {
                    throw new ParseError(`Expected one of "<>AV=|." after @`,
                        rowNodes[j]);
                }
                */
        // Now join the arrow to its labels.
        // const arrow: AnyParseNode = cdArrow(arrowChar, labels, parser);
        var arrow = StretchyOpNode(
            above: EquationRowNode(children: [SymbolNode(symbol: "")]),
            below: EquationRowNode(children: [SymbolNode(symbol: "")]),
            symbol: "");

        row.add(EquationRowNode(children: [arrow]));
        // In CD's syntax, cells are implicit. That is, everything that
        // is not an arrow gets collected into a cell. So create an empty
        // cell now. It will collect upcoming parseNodes.
        cell = EquationRowNode(children: []);
      }
    }
    if (i % 2 == 0) {
      // Even-numbered rows consist of: cell, arrow, cell, arrow, ... cell
      // The last cell is not yet pushed into `row`, so:
      row.add(cell);
    } else {
      // Odd-numbered rows consist of: vert arrow, empty cell, ... vert arrow
      // Remove the empty cell that was placed at the beginning of `row`.
      row.removeAt(0);
    }
    row = [];
    body.add(row);
  }

  // End row group
  parser.macroExpander.endGroup();
  // End array group defining \\
  parser.macroExpander.endGroup();

  // define column separation.
  /*
  const cols = new Array(body[0].length).fill({
    type: "align",
    align: "c",
    pregap: 0.25, // CD package sets \enskip between columns.
    postgap: 0.25, // So pre and post each get half an \enskip, i.e. 0.25em.
  });
  */
  return MatrixNode(
    body: body,
    // vLines: separators,
    // columnAligns: colAligns,
    // rowSpacings: rowGaps,
    // arrayStretch: arrayStretch,
    // hLines: hLinesBeforeRow,
    // hskipBeforeAndAfter: hskipBeforeAndAfter,
    // isSmall: isSmall,
  );
  /*
   {
    type: "array",
    mode: "math",
    body,
    arraystretch: 1,
    addJot: true,
    rowGaps: [null],
    cols,
    colSeparationType: "CD",
    hLinesBeforeRow: new Array(body.length + 1).fill([]),
  };*/

/*
  
  // Start group for first cell
  parser.macroExpander.beginGroup();

  var row = <EquationRowNode>[];
  final body = [row];
  final rowGaps = <Measurement>[];
  final hLinesBeforeRow = <MatrixSeparatorStyle>[];

  // Test for \hline at the top of the array.
  hLinesBeforeRow
      .add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);

  while (true) {
    // Parse each cell in its own group (namespace)
    final cellBody =
        parser.parseExpression(breakOnInfix: false, breakOnTokenText: '\\cr');
    parser.macroExpander.endGroup();
    parser.macroExpander.beginGroup();

    final cell = style == null
        ? cellBody.wrapWithEquationRow()
        : StyleNode(
            children: cellBody,
            optionsDiff: OptionsDiff(style: style),
          ).wrapWithEquationRow();
    row.add(cell);

    final next = parser.fetch().text;
    if (next == '&') {
      parser.consume();
    } else if (next == '\\end') {
      // Arrays terminate newlines with `\crcr` which consumes a `\cr` if
      // the last line is empty.
      // NOTE: Currently, `cell` is the last item added into `row`.
      if (row.length == 1 && cellBody.isEmpty) {
        body.removeLast();
      }
      if (hLinesBeforeRow.length < body.length + 1) {
        hLinesBeforeRow.add(MatrixSeparatorStyle.none);
      }
      break;
    } else if (next == '\\cr') {
      final cr = assertNodeType<CrNode>(parser.parseFunction(null, null, null));
      rowGaps.add(cr.size ?? Measurement.zero);

      // check for \hline(s) following the row separator
      hLinesBeforeRow
          .add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);

      row = [];
      body.add(row);
    } else {
      throw ParseException(
          'Expected & or \\\\ or \\cr or \\end', parser.nextToken);
    }
  }

  // End cell group
  parser.macroExpander.endGroup();
  // End array group defining \\
  parser.macroExpander.endGroup();

  return MatrixNode(
    body: body,
    vLines: separators,
    columnAligns: colAligns,
    rowSpacings: rowGaps,
    arrayStretch: arrayStretch,
    hLines: hLinesBeforeRow,
    hskipBeforeAndAfter: hskipBeforeAndAfter,
    isSmall: isSmall,
  );
  */
}
/*
export function parseCD(parser: Parser): ParseNode<"array"> {
    // Get the array's parse nodes with \\ temporarily mapped to \cr.
    const parsedRows: AnyParseNode[][] = [];
    parser.gullet.beginGroup();
    parser.gullet.macros.set("\\cr", "\\\\\\relax");
    parser.gullet.beginGroup();
    while (true) {  // eslint-disable-line no-constant-condition
        // Get the parse nodes for the next row.
        parsedRows.push(parser.parseExpression(false, "\\\\"));
        parser.gullet.endGroup();
        parser.gullet.beginGroup();
        const next = parser.fetch().text;
        if (next === "&" || next === "\\\\") {
            parser.consume();
        } else if (next === "\\end") {
            if (parsedRows[parsedRows.length - 1].length === 0) {
                parsedRows.pop(); // final row ended in \\
            }
            break;
        } else {
            throw new ParseError("Expected \\\\ or \\cr or \\end",
                                 parser.nextToken);
        }
    }

    let row = [];
    const body = [row];
   // Loop thru the parse nodes. Collect them into cells and arrows.
    for (let i = 0; i < parsedRows.length; i++) {
        // Start a new row.
        const rowNodes = parsedRows[i];
        // Create the first cell.
        let cell = newCell();

        for (let j = 0; j < rowNodes.length; j++) {
            if (!isStartOfArrow(rowNodes[j])) {
                // If a parseNode is not an arrow, it goes into a cell.
                cell.body.push(rowNodes[j]);
            } else {
                // Parse node j is an "@", the start of an arrow.
                // Before starting on the arrow, push the cell into `row`.
                row.push(cell);

                // Now collect parseNodes into an arrow.
                // The character after "@" defines the arrow type.
                j += 1;
                const arrowChar = assertSymbolNodeType(rowNodes[j]).text;

                // Create two empty label nodes. We may or may not use them.
                const labels: ParseNode<"ordgroup">[] = new Array(2);
                labels[0] = {type: "ordgroup", mode: "math", body: []};
                labels[1] = {type: "ordgroup", mode: "math", body: []};

                // Process the arrow.
                if ("=|.".indexOf(arrowChar) > -1) {
                    // Three "arrows", ``@=`, `@|`, and `@.`, do not take labels.
                    // Do nothing here.
                } else if ("<>AV".indexOf(arrowChar) > -1) {
                    // Four arrows, `@>>>`, `@<<<`, `@AAA`, and `@VVV`, each take
                    // two optional labels. E.g. the right-point arrow syntax is
                    // really:  @>{optional label}>{optional label}>
                    // Collect parseNodes into labels.
                    for (let labelNum = 0; labelNum < 2; labelNum++) {
                        let inLabel = true;
                        for (let k = j + 1; k < rowNodes.length; k++) {
                            if (isLabelEnd(rowNodes[k], arrowChar)) {
                                inLabel = false;
                                j = k;
                                break;
                            }
                            if (isStartOfArrow(rowNodes[k])) {
                                throw new ParseError("Missing a " + arrowChar +
                                " character to complete a CD arrow.", rowNodes[k]);
                            }

                            labels[labelNum].body.push(rowNodes[k]);
                        }
                        if (inLabel) {
                            // isLabelEnd never returned a true.
                            throw new ParseError("Missing a " + arrowChar +
                                " character to complete a CD arrow.", rowNodes[j]);
                        }
                    }
                } else {
                    throw new ParseError(`Expected one of "<>AV=|." after @`,
                        rowNodes[j]);
                }
               // Now join the arrow to its labels.
                const arrow: AnyParseNode = cdArrow(arrowChar, labels, parser);

                // Wrap the arrow in  ParseNode<"styling">.
                // This is done to match parseArray() behavior.
                const wrappedArrow = {
                    type: "styling",
                    body: [arrow],
                    mode: "math",
                    style: "display", // CD is always displaystyle.
                };
                row.push(wrappedArrow);
                // In CD's syntax, cells are implicit. That is, everything that
                // is not an arrow gets collected into a cell. So create an empty
                // cell now. It will collect upcoming parseNodes.
                cell = newCell();
            }
        }
        if (i % 2 === 0) {
            // Even-numbered rows consist of: cell, arrow, cell, arrow, ... cell
            // The last cell is not yet pushed into `row`, so:
            row.push(cell);
        } else {
            // Odd-numbered rows consist of: vert arrow, empty cell, ... vert arrow
            // Remove the empty cell that was placed at the beginning of `row`.
            row.shift();
        }
        row = [];
        body.push(row);
    }

    // End row group
    parser.gullet.endGroup();
    // End array group defining \\
    parser.gullet.endGroup();

    // define column separation.
    const cols = new Array(body[0].length).fill({
        type: "align",
        align: "c",
        pregap: 0.25,  // CD package sets \enskip between columns.
        postgap: 0.25, // So pre and post each get half an \enskip, i.e. 0.25em.
    });

    return {
        type: "array",
        mode: "math",
        body,
        arraystretch: 1,
        addJot: true,
        rowGaps: [null],
        cols,
        colSeparationType: "CD",
        hLinesBeforeRow: new Array(body.length + 1).fill([]),
    };
}
*/