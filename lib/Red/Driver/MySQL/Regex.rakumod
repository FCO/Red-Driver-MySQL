use Red::Regex;
use Red::Regex::Automaton;
unit class Red::Driver::MySQL::Regex is Red::Regex;

method render(Str:D :$dialect = 'MySQL' --> Str:D) {
    self.render-info(:$dialect)<pattern>
}

method render-info(Str:D :$dialect = 'MySQL', :@capture-ids = (),
    Bool :$whole = False --> Hash:D) {
    self.unsupported("Unknown regex dialect: $dialect") unless $dialect eq 'MySQL';
    my %*RED-REGEX-REFERENCED;
    my %*RED-REGEX-CAPTURES;
    my Int $*RED-REGEX-NEXT-CAPTURE = $whole ?? 1 !! 0;
    %*RED-REGEX-REFERENCED{$_} = True for @capture-ids;
    self.walk(-> $part {
        self.unsupported('Whole match reads with Match boundary markers are not implemented')
            if $whole && $part[0] eq 'match-boundary';
        if $part[0] eq 'backreference' {
            %*RED-REGEX-REFERENCED{$_} = True for $part[1].list;
        }
    });
    my $pattern = self!render(self.tree, $dialect, True);
    $pattern = '(?:)' unless $pattern.chars;
    $pattern = '(' ~ $pattern ~ ')' if $whole;
    { :$pattern, :groups(%*RED-REGEX-CAPTURES.Map) }
}

method !render($tree, Str:D $dialect, Bool $root = False, Bool $ignore = False --> Str:D) {
    my @part = $tree.list;
    given @part[0] {
        when 'empty' | 'match-boundary' { '' }
        when 'never' { '(?!)' }
        when 'literal-slot' { self.unsupported('Regex literal interpolation needs bound values') }
        when 'literal' { self.escape(@part[1]) }
        when 'sequence' { @part.skip(1).map({ self!render($_, $dialect, False, $ignore) }).join }
        when 'alternative' {
            '(?:' ~ @part.skip(1).map({ self!render($_, $dialect, False, $ignore) }).join('|') ~ ')'
        }
        when 'group' | 'scope' { '(?:' ~ self!render(@part[1], $dialect, False, $ignore) ~ ')' }
        when 'capture' {
            my $needed = so %*RED-REGEX-REFERENCED{@part[1]};
            if $needed {
                my Bool $boundary = False;
                self.walk(-> $node { $boundary = True if $node[0] eq 'match-boundary' }, @part[2]);
                self.unsupported('Capture references crossing Match boundaries are not supported')
                    if $boundary;
            }
            %*RED-REGEX-CAPTURES{@part[1]} = ++$*RED-REGEX-NEXT-CAPTURE if $needed;
            ($needed ?? '(' !! '(?:') ~ self!render(@part[2], $dialect, False, $ignore) ~ ')'
        }
        when 'backreference' {
            my @groups = @part[1].list.map({ %*RED-REGEX-CAPTURES{$_} }).grep(*.defined);
            self.unsupported('Forward or unmatched capture references are not supported')
                unless @groups;
            ($ignore ?? '(?-i:' !! '(?:') ~ @groups.map({ '\\' ~ $_ }).join('|') ~ ')'
        }
        when 'mode' {
            my $enabled = @part[1];
            '(?' ~ ($enabled ?? 'i' !! '-i') ~ ':'
                    ~ self!render(@part[2], $dialect, False, $enabled) ~ ')'
        }
        when 'intersection' {
            my Bool $same = False;
            self.walk(-> $node { $same = True if $node[0] eq 'same' }, @part);
            self.unsupported('MySQL same-character assertions combined with conjunction are not supported')
                if $same;
            Red::Regex::Automaton.new(:tree(@part.List), :$ignore).render(
                -> $test, Bool $case {
                    if $test[0] eq 'empty' {
                        ''
                    } else {
                        my $label = $case == $ignore ?? $test !! ['mode', $case, $test];
                        self!render($label, $dialect, False, $ignore)
                    }
                })
        }
        when 'both' {
            my $left = @part[2] == $ignore ?? @part[1] !! ['mode', @part[2], @part[1]];
            my $right = @part[4] == $ignore ?? @part[3] !! ['mode', @part[4], @part[3]];
            '(?=' ~ self!render($left, $dialect, False, $ignore) ~ ')'
                ~ self!render($right, $dialect, False, $ignore)
        }
        when 'atomic' {
            '(?>' ~ self!render(@part[1], $dialect, False, $ignore) ~ ')'
        }
        when 'any' { '.' }
        when 'class' {
            my %classes = digit => '[:digit:]', word => '[:alnum:]_', space => '[:space:]',
                alpha => '[:alpha:]_', alnum => '[:alnum:]_', lower => '[:lower:]',
                upper => '[:upper:]', xdigit => '0-9A-Fa-f', blank => '[:blank:]',
                cntrl => '[:cntrl:]', graph => '[:graph:]', print => '[:print:]',
                punct => '[:punct:]';
            self.unsupported("Unknown character class: {@part[1]}")
                unless %classes{@part[1]}:exists;
            '[' ~ (@part[2] ?? '^' !! '') ~ %classes{@part[1]} ~ ']'
        }
        when 'ranges' {
            my &escape = -> Int:D $point {
                $point <= 0xFFFF ?? '\u' ~ $point.fmt('%04X')
                    !! '\U' ~ $point.fmt('%08X')
            };
            # An empty Unicode category is a valid set that matches no character.
            return '(?!)' unless @part[1].elems || @part[2];
            return '.' unless @part[1].elems;
            '[' ~ (@part[2] ?? '^' !! '') ~ @part[1].map({
                escape(.[0]) ~ (.[0] == .[1] ?? '' !! '-' ~ escape(.[1]))
            }).join ~ ']'
        }
        when 'set' {
            my $left = self!render(@part[2], $dialect, False, $ignore);
            my $right = self!render(@part[3], $dialect, False, $ignore);
            @part[1] eq 'union' ?? '(?:' ~ $left ~ '|' ~ $right ~ ')'
                !! @part[1] eq 'intersect' ?? '(?=' ~ $left ~ ')' ~ $right
                !! '(?!' ~ $right ~ ')' ~ $left
        }
        when 'characters' {
            my $positive = '(?:' ~ @part[1].ords.map({ self.escape(.chr) }).join('|') ~ ')';
            @part[2] ?? '(?!' ~ $positive ~ ').' !! $positive
        }
        when 'same' {
            my $slot = ++$*RED-REGEX-NEXT-CAPTURE;
            # Raku's same assertion compares exactly, even under :i.
            my $test = '(?-i:(?<=(.))(?=\\' ~ $slot ~ '))';
            @part[1] ?? '(?!' ~ $test ~ ')' !! $test
        }
        when 'anchor' {
            my $end = '\z';
            given @part[1] {
                when 'begin' { '\A' }
                when 'end' { $end }
                when 'line-begin' { '(?:\A|(?<=\n))' }
                when 'line-end' { '(?:' ~ $end ~ '|(?=\n))' }
                when 'word-left' { '(?<!\w)(?=\w)' }
                when 'word-right' { '(?<=\w)(?!\w)' }
                when 'word' { '\b' }
                when 'not-word' { '\B' }
                when 'not-within-word' { '(?:(?<!\w)|(?!\w))' }
                when 'within-word' { '(?<=\w)(?=\w)' }
                default { self.unsupported("Unknown anchor: {@part[1]}") }
            }
        }
        when 'look' {
            self.unsupported('MySQL requires a bounded lookbehind')
                if @part[1] eq 'after'
                    && self.maximum-width(@part[3]) == Inf;
            '(' ~ (@part[1] eq 'after' ?? '?<' !! '?') ~ (@part[2] ?? '!' !! '=')
                ~ self!render(@part[3], $dialect, False, $ignore) ~ ')'
        }
        when 'repeat' {
            my ($body, $minimum, $maximum, $frugal) = @part[1..4];
            my $suffix = $minimum == 0 && $maximum == -1 ?? '*'
                !! $minimum == 1 && $maximum == -1 ?? '+'
                !! $minimum == 0 && $maximum == 1 ?? '?'
                !! '{' ~ $minimum ~ ',' ~ ($maximum == -1 ?? '' !! $maximum) ~ '}';
            '(?:' ~ self!render($body, $dialect, False, $ignore) ~ ')' ~ $suffix ~ ($frugal ?? '?' !! '')
        }
        default { self.unsupported("Unsupported operation {@part[0]} on $dialect") }
    }
}

