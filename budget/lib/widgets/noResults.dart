import 'package:budget/colors.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

class NoResults extends StatelessWidget {
  const NoResults({
    Key? key,
    required this.message,
    this.tintColor,
    this.padding,
    this.noSearchResultsVariation = false,
  }) : super(key: key);
  final String message;
  final Color? tintColor;
  final EdgeInsetsDirectional? padding;
  final bool noSearchResultsVariation;

  @override
  Widget build(BuildContext context) {
    return FadeIn(
      duration: Duration(milliseconds: 200),
      child: Opacity(
        opacity: Theme.of(context).brightness == Brightness.light ? 1 : 0.8,
        child: Center(
          child: Padding(
            padding: padding ??
                EdgeInsetsDirectional.only(
                  top: MediaQuery.sizeOf(context).height * 0.4 > 400 ? 100 : 35,
                  end: 30,
                  start: 30,
                ),
            child: Column(
              children: [
                Container(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).height <=
                              MediaQuery.sizeOf(context).width
                          ? MediaQuery.sizeOf(context).height * 0.4 > 400
                              ? 400
                              : MediaQuery.sizeOf(context).height * 0.4
                          : 270),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tintColor?.withOpacity(0.25) ??
                            Theme.of(context).colorScheme.primaryContainer,
                      ),
                      child: FractionallySizedBox(
                        widthFactor: 0.5,
                        heightFactor: 0.5,
                        child: FittedBox(
                          child: Icon(
                            noSearchResultsVariation
                                ? Icons.search_off_rounded
                                : Icons.inbox_rounded,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 30),
                TextFont(
                  maxLines: 4,
                  fontSize: 15,
                  text: message,
                  textAlign: TextAlign.center,
                  textColor: getColor(context, "textLight"),
                ),
                // Lottie.asset('assets/animations/search-animation.json'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
