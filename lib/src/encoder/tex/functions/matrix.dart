part of '../functions.dart';

StretchyOpNode? getCdArrow(GreenNode n) {
  if (!(n is EquationRowNode)) return null;
  if (n.children.length != 1) return null;
  GreenNode c = n.children[0];
  if (!(c is StretchyOpNode)) return null;
  return c;
}

CdVertArrowNode? getCdVArrow(GreenNode n) {
  if (!(n is EquationRowNode)) return null;
  if (n.children.length != 1) return null;
  GreenNode c = n.children[0];
  if (!(c is CdVertArrowNode)) return null;
  return c;
}

EncodeResult _matrixEncoder(GreenNode node) {
  var mn = node as MatrixNode;
  if (!mn.isCD) {
    return NonStrictEncodeResult.string(
      'unknown symbol',
      'only support the following type of matrix: cd',
      '.',
    );
  }

  // for now use only undecorated arrow
  List<String> results = <String>[];
  int rowCount = 0;
  for (var row in mn.body) {
    // sometimess the last row is empty
    if (rowCount == mn.body.length - 1) {
      bool hasContent = false;
      for (var col in row) {
        if (col != null) {
          hasContent = true;
          break;
        }
      }
      if (!hasContent) break;
    }
    if ((rowCount % 2) == 0) {
      int colCount = 0;
      for (var col in row) {
        if ((colCount % 2) == 0) {
          results.add(encodeTex(col!).stringify(const TexEncodeConf()));
        } else {
          var cdArrow = getCdArrow(col!);
          if (cdArrow != null) {
            String upperLabel = "";
            if (cdArrow.above != null) {
              upperLabel =
                  encodeTex(cdArrow.above!).stringify(const TexEncodeConf());
            }
            String lowerLabel = "";
            if (cdArrow.below != null) {
              lowerLabel =
                  encodeTex(cdArrow.below!).stringify(const TexEncodeConf());
            }
            results.add("@>${upperLabel}>${lowerLabel}>");
          } else {
            results.add("@>>>");
          }
        }
        colCount++;
      }
    } else {
      int colCount = 0;
      for (var col in row) {
        if ((colCount % 2) == 0) {
          var cdArrow = getCdVArrow(col!);
          if (cdArrow != null) {
            String leftLabel = "";
            if (cdArrow.labels[0] != null) {
              leftLabel = encodeTex(cdArrow.labels[0]!)
                  .stringify(const TexEncodeConf());
            }
            String rightLabel = "";
            if (cdArrow.labels[1] != null) {
              rightLabel = encodeTex(cdArrow.labels[1]!)
                  .stringify(const TexEncodeConf());
            }
            results.add("@V${leftLabel}V${rightLabel}V");
          } else {
            results.add("@VVV");
          }
        }
        colCount++;
      }
    }
    results.add("\\\\");
    rowCount++;
  }
  String r = "\\begin{CD} " + results.join(" ") + " \\end{CD}";
  return StaticEncodeResult(r);
}
