use Red::Index;
use X::Red::Exceptions;
unit module Red::Driver::MySQL::IndexKeys;

# STATISTICS prints introduced literals with an extra escaping layer and exposes
# their bytes as latin1 characters. Decode only that marked catalog spelling;
# ordinary SQL literals and quoted identifiers must not be rewritten globally.
sub mysql-index-key-sql(Str $sql, Bool :$catalog = False --> Str) {
    my @chars = $sql.comb;
    my Int $i = 0;
    my @tokens;
    sub literal(Str $charset, Bool $catalog --> Str) {
        $i += $catalog ?? 2 !! 1;
        sub next-char() {
            my $char = @chars[$i++];
            $char = @chars[$i++] if $catalog && $char eq '\\' && $i < @chars;
            $char
        }
        my Str $value = '';
        my Bool $closed = False;
        while $i < @chars {
            my $char = next-char();
            if $char eq "'" {
                my $position = $i;
                if $i < @chars && next-char() eq "'" {
                    $value ~= "'";
                    next;
                }
                $i = $position;
                $closed = True;
                last;
            }
            if $char eq '\\' && $i < @chars {
                my $escaped = next-char();
                $value ~= do given $escaped {
                    when '0' { "\0" }
                    when 'b' { "\b" }
                    when 'n' { "\n" }
                    when 'r' { "\r" }
                    when 't' { "\t" }
                    when 'Z' { chr(26) }
                    when '%' | '_' { '\\' ~ $_ }
                    default { $_ }
                };
            } else {
                $value ~= $char;
            }
        }
        index-error('Unterminated MySQL index literal') unless $closed;
        if $catalog && $charset eq '_utf8mb4' {
            $value = $value.encode('latin-1').decode('utf8', :strict);
        }
        # The driver configures utf8mb4; its implicit literal charset is identical
        # to an explicit _utf8mb4 introducer. Other charsets stay distinguishable.
        ($charset eq '_utf8mb4' ?? '' !! $charset)
            ~ "'" ~ $value.subst('\\', '\\\\', :g).subst("'", "''", :g) ~ "'"
    }
    while $i < @chars {
        my $char = @chars[$i];
        if $char ~~ /\s/ {
            $i++;
        } elsif $char eq "'" {
            @tokens.push: literal('', False);
        } elsif $char eq '`' || $char eq '"' {
            my $quote = $char;
            my $token = @chars[$i++];
            while $i < @chars {
                my $next = @chars[$i++];
                $token ~= $next;
                if $next eq $quote {
                    if $i < @chars && @chars[$i] eq $quote {
                        $token ~= @chars[$i++];
                    } else {
                        last;
                    }
                }
            }
            @tokens.push: $catalog
                ?? $token.encode('latin-1').decode('utf8', :strict) !! $token;
        } elsif $char ~~ /<[\w\$]>/ {
            my $word = '';
            $word ~= @chars[$i++] while $i < @chars && @chars[$i] ~~ /<[\w\$]>/;
            my $after-word = $i;
            $i++ while $i < @chars && @chars[$i] ~~ /\s/;
            my $catalog = $i + 1 < @chars && @chars[$i] eq '\\'
                && @chars[$i + 1] eq "'";
            if $word.starts-with('_') && ($catalog || ($i < @chars && @chars[$i] eq "'")) {
                @tokens.push: literal($word.lc, so $catalog);
            } else {
                my %aliases = lcase => 'lower', ucase => 'upper', substring => 'substr';
                $word = %aliases{$word.lc} // $word
                    if $i < @chars && @chars[$i] eq '(';
                @tokens.push: $word;
                $i = $after-word;
            }
        } else {
            @tokens.push: @chars[$i++];
        }
    }
    # Preserve casts, lengths, collations and grouping. MySQL appends the default
    # charset to CHAR casts, so make that implicit default explicit on both sides.
    my Int $position = 0;
    while $position < @tokens {
        my $token = @tokens[$position++];
        next unless $token.lc eq 'char' && $position > 1
            && @tokens[$position - 2].lc eq 'as';
        my $end = $position;
        if $end < @tokens && @tokens[$end] eq '(' {
            my $depth = 0;
            repeat {
                $depth++ if @tokens[$end] eq '(';
                $depth-- if @tokens[$end] eq ')';
                $end++;
            } while $end < @tokens && $depth;
        }
        @tokens.splice($end, 2, 'charset') if $end + 1 < @tokens
            && @tokens[$end].lc eq 'character' && @tokens[$end + 1].lc eq 'set';
        @tokens.splice($end, 0, 'charset', 'utf8mb4')
            if $end < @tokens && @tokens[$end] eq ')';
    }
    @tokens.join(' ')
}

# Return executable SQL spelling for catalog expressions, not the extra-escaped
# representation printed by information_schema.STATISTICS.
sub mysql-index-catalog-key(Str $sql --> Str) is export {
    CATCH {
        when X::Red::Index { .rethrow }
        default { index-error("Cannot decode MySQL index catalog expression: {.message}") }
    }
    mysql-index-key-sql($sql, :catalog)
}

sub mysql-index-key(Str $sql --> Str) is export {
    canonical-index-key(mysql-index-key-sql($sql))
}
