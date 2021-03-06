# $Id$
##############################################################################
#
#     98_WeekdayTimer.pm
#     written by Dietmar Ortmann
#     modified by Tobias Faust
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################

package main;
use strict;
use warnings;
use POSIX;

use Time::Local 'timelocal_nocheck';

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

################################################################################
sub WeekdayTimer_Initialize($){
  my ($hash) = @_;

  if(!$modules{Twilight}{LOADED} && -f "$attr{global}{modpath}/FHEM/59_Twilight.pm") {
    my $ret = CommandReload(undef, "59_Twilight");
    Log3 undef, 1, $ret if($ret);
  }

# Consumer
  $hash->{SetFn}   = "WeekdayTimer_Set";
  $hash->{DefFn}   = "WeekdayTimer_Define";
  $hash->{UndefFn} = "WeekdayTimer_Undef";
  $hash->{GetFn}   = "WeekdayTimer_Get";
  $hash->{AttrFn}  = "WeekdayTimer_Attr";  
  $hash->{UpdFn}   = "WeekdayTimer_Update";
  $hash->{AttrList}= "disable:0,1 delayedExecutionCond ".
     $readingFnAttributes;                                               
}
################################################################################
sub WeekdayTimer_InitHelper($) {
  my ($hash) = @_;
   
  $hash->{longDays} =  { "de" => ["Sonntag",  "Montag","Dienstag","Mittwoch",  "Donnerstag","Freitag", "Samstag",  "Wochenende", "Werktags" ],
                         "en" => ["Sunday",   "Monday","Tuesday", "Wednesday", "Thursday",  "Friday",  "Saturday", "weekend",    "weekdays" ],
                         "fr" => ["Dimanche", "Lundi", "Mardi",   "Mercredi",  "Jeudi",     "Vendredi","Samedi",   "weekend",    "jours de la semaine"]};
  $hash->{shortDays} = { "de" => ["so",       "mo",    "di",      "mi",        "do",        "fr",      "sa",       '$we',        '!$we'     ],    
                         "en" => ["su",       "mo",    "tu",      "we",        "th",        "fr",      "sa",       '$we',        '!$we'     ],
                         "fr" => ["di",       "lu",    "ma",      "me",        "je",        "ve",      "sa",       '$we',        '!$we'     ]};
}
################################################################################
sub WeekdayTimer_Set($@) {
  my ($hash, @a) = @_;
  
  return "no set value specified" if(int(@a) < 2);
  return "Unknown argument $a[1], choose one of enable disable " if($a[1] eq "?");
  
  my $name = shift @a;
  my $v = join(" ", @a);

  Log3 $hash, 3, "[$name] set $name $v";
  
  if      ($v eq "enable") {
     fhem("attr $name disable 0"); 
  } elsif ($v eq "disable") {
     fhem("attr $name disable 1"); 
  }
  return undef;
}
################################################################################
sub WeekdayTimer_Get($@) {
  my ($hash, @a) = @_;
  return "argument is missing" if(int(@a) != 2);

  $hash->{LOCAL} = 1;
  delete $hash->{LOCAL};
  my $reading= $a[1];
  my $value;

  if(defined($hash->{READINGS}{$reading})) {
        $value= $hash->{READINGS}{$reading}{VAL};
  } else {
        return "no such reading: $reading";
  }
  return "$a[0] $reading => $value";
}
################################################################################
sub WeekdayTimer_Undef($$) {
  my ($hash, $arg) = @_;

  foreach my $time (keys %{$hash->{profil}}) {
     myRemoveInternalTimer($time, $hash);
  }
  myRemoveInternalTimer("SetTimerOfDay", $hash);
  delete $modules{$hash->{TYPE}}{defptr}{$hash->{NAME}};
  return undef;
}  
################################################################################
sub WeekdayTimer_Define($$) {
  my ($hash, $def) = @_;
  WeekdayTimer_InitHelper($hash);

  my  @a = split("[ \t]+", $def);

  return "Usage: define <name> $hash->{TYPE} <device> <language> <switching times> <condition|command>"
     if(@a < 4);

  #fuer den modify Altlasten bereinigen
  delete($hash->{helper});

  my $name     = shift @a;
  my $type     = shift @a;
  my $device   = shift @a;
  
  WeekdayTimer_DeleteTimer($hash);
  my $delVariables = "(CONDITION|COMMAND|profile|Profil)";   
  map { delete $hash->{$_} if($_=~ m/^$delVariables.*/g) }  keys %{$hash};
  
  my $language = WeekdayTimer_Language  ($hash, \@a);
  
  my $idx = 0; 
  $hash->{dayNumber}    = {map {$_ => $idx++}     @{$hash->{shortDays}{$language}}};  
  $hash->{helper}{daysRegExp}        = '(' . join ("|",        @{$hash->{shortDays}{$language}}) . ")";
  $hash->{helper}{daysRegExpMessage} = $hash->{helper}{daysRegExp};
  
  $hash->{helper}{daysRegExp}   =~ s/\$/\\\$/g; 
  $hash->{helper}{daysRegExp}   =~ s/\!/\\\!/g; 

  WeekdayTimer_GlobalDaylistSpec ($hash, \@a);
   
  my @switchingtimes       = WeekdayTimer_gatherSwitchingTimes (\@a);
  my $conditionOrCommand   = join (" ", @a);

  # test if device is defined
  Log3 ($hash, 3, "[$name] invalid device, <$device> not found") if(!$defs{$device});
  
  # wenn keine switchintime angegeben ist, dann Fehler
  Log3 ($hash, 3, "[$name] no valid Switchingtime found in <$conditionOrCommand>, check first parameter")  if (@switchingtimes == 0);

  $hash->{TYPE}           = $type;  
  $hash->{NAME}           = $name;
  $hash->{DEVICE}         = $device;
  $hash->{SWITCHINGTIMES} = \@switchingtimes;

  $modules{$hash->{TYPE}}{defptr}{$hash->{NAME}} = $hash;
  
  if($conditionOrCommand =~  m/^\(.*\)$/g) {         #condition (*)
     $hash->{CONDITION} = $conditionOrCommand;
  } elsif(length($conditionOrCommand) > 0 ) {
     $hash->{COMMAND} = $conditionOrCommand;
  }
  
 #WeekdayTimer_DeleteTimer($hash);  am Anfang dieser Routine
  WeekdayTimer_Profile    ($hash);
  WeekdayTimer_SetTimer   ($hash);
  
  WeekdayTimer_SetTimerForMidnightUpdate( { HASH => $hash} );
  
  return undef;
}
################################################################################
sub WeekdayTimer_Profile($) {   
  my $hash = shift;
  
  my $nochZuAendern  = 0;  #  $d
  my $language =   $hash->{LANGUAGE};
  my %longDays = %{$hash->{longDays}}; 
  
  delete $hash->{profil};
  my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time()); 
  
  my $now = time();   
# ------------------------------------------------------------------------------
  foreach  my $st (@{$hash->{SWITCHINGTIMES}}) {
     my ($tage,$time,$parameter) = WeekdayTimer_SwitchingTime ($hash, $st);
     
     foreach  my $d (@{$tage}) {

        my $dayOfEchteZeit = $d;
        if      ($d==7) {                                   # Weekend
           $dayOfEchteZeit = ($wday ~~ [1..5]) ? 6 : $wday; # ggf. Samstag  
        } elsif ($d==8) {                                   # day of Week
           $dayOfEchteZeit = ($wday ~~ [0..6]) ? 1 : $wday; # ggf. Montag
        }

        my $echtZeit = WeekdayTimer_EchteZeit($hash, $dayOfEchteZeit, $time); 
        $hash->{profile}{$d}{$echtZeit}        = $parameter;
     }
  }
# ------------------------------------------------------------------------------
  foreach  my $st (@{$hash->{SWITCHINGTIMES}}) {
     my ($tage,$time,$parameter)     = WeekdayTimer_SwitchingTime ($hash, $st);
     my $echtZeit                    = WeekdayTimer_EchteZeit     ($hash, $wday, $time); 
     my ($stunde, $minute, $sekunde) = split (":",$echtZeit);              

     $hash->{profil}     {$echtZeit}{PARA}  = $parameter;
     $hash->{profil}     {$echtZeit}{TIM}   = WeekdayTimer_zeitErmitteln ($now, $stunde, $minute, $sekunde, 0);
     $hash->{profil}     {$echtZeit}{TAGE}  = $tage;
  }
# ------------------------------------------------------------------------------
  Log3 $hash, 4,  "[$hash->{NAME}] " . sunrise_abs() . " " . sunset_abs() . " " . $longDays{$language}[$wday]; 
  foreach  my $d (sort keys %{$hash->{profile}}) {
       my $profiltext = "";
       foreach  my $t (sort keys %{$hash->{profile}{$d}}) {
           $profiltext .= "$t " .  $hash->{profile}{$d}{$t} . ", "; 
       }
       my $profilKey  = "Profil $d: $longDays{$language}[$d]";
       $profiltext =~ s/, $//;
       $hash->{$profilKey} = $profiltext;
       Log3 $hash, 4,  "[$hash->{NAME}] $profiltext ($profilKey)";  
  }
  delete $hash->{profile};
}
################################################################################   
sub WeekdayTimer_SwitchingTime($$) {
    my ($hash, $switchingtime) = @_;
    
    my $name = $hash->{NAME};
    my $globalDaylistSpec = $hash->{GlobalDaylistSpec};
    my @tageGlobal = @{WeekdayTimer_daylistAsArray($hash, $globalDaylistSpec)}; 
    
    my (@st, $daylist, $time, $timeString, $para);
    @st = split(/\|/, $switchingtime);
    
    if ( @st == 2) {    
      $daylist = ($globalDaylistSpec gt "") ? $globalDaylistSpec : "0123456";
      $time    = $st[0];
      $para    = $st[1];
    } elsif ( @st == 3) {
      $daylist  = $st[0];
      $time     = $st[1];
      $para     = $st[2];
    }
    
    my @tage = @{WeekdayTimer_daylistAsArray($hash, $daylist)}; 
    my $tage=@tage;
    if ( $tage==0 ) {
       Log3 ($hash, 1, "[$name] invalid daylist in $name <$daylist> use one of 012345678 or $hash->{helper}{daysRegExpMessage}");
    }       

    my %hdays=();
    @hdays{@tageGlobal} = undef;
    @hdays{@tage}       = undef;
    @tage = sort keys %hdays;
    
   #Log3 $hash, 3, "Tage: " . Dumper \@tage;
    return (\@tage,$time,$para);
}

################################################################################   
sub WeekdayTimer_daylistAsArray($$){
    my ($hash, $daylist) = @_;
    
    my $name = $hash->{NAME};
    my @days;
    
    my %hdays=();

    $daylist = lc($daylist); 
    # Angaben der Tage verarbeiten
    # Aufzaehlung 1234 ...
    if (      $daylist =~  m/^[0-8]{0,9}$/g) {
        
        Log3 ($hash, 3, "[$name] " . '"7" in daylist now means $we(weekend) - see dokumentation!!!' ) 
           if (index($daylist, '7') != -1);
        
        @days = split("", $daylist);
        @hdays{@days} = undef;

    # Aufzaehlung Sa,So,... | Mo-Di,Do,Fr-Mo
    } elsif ($daylist =~  m/^($hash->{helper}{daysRegExp}(,|-|$)){0,7}$/g   ) {
      my @subDays;
      my @aufzaehlungen = split (",", $daylist);
      foreach my $einzelAufzaehlung (@aufzaehlungen) {
         my @days = split ("-", $einzelAufzaehlung);
         my $days = @days; 
         if ($days == 1) {
           #einzelner Tag: Sa
           $hdays{$hash->{dayNumber}{$days[0]}} = undef;    
         } else {  
           # von bis Angabe: Mo-Di
           my $von  = $hash->{dayNumber}{$days[0]};
           my $bis  = $hash->{dayNumber}{$days[1]};
           if ($von <= $bis) {
              @subDays = ($von .. $bis);
           } else {
             #@subDays = ($dayNumber{so} .. $bis, $von .. $dayNumber{sa});
              @subDays = (           00  .. $bis, $von ..            06);
           }
           @hdays{@subDays}=undef;           
         }
      }
    } else{
      %hdays = ();
    }
    
    my @tage = sort keys %hdays;
    return \@tage;
}
################################################################################   
sub WeekdayTimer_EchteZeit($$$) {
    my ($hash, $d, $time)  = @_; 
    
    my $name = $hash->{NAME};
    
    my $now = time();
    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($now); 

    my $listOfDays = "";

    # Zeitangabe verarbeiten.    
    $time = '"' . "$time" . '"'       if($time !~  m/^\{.*\}$/g);       
    my $date           = $now+($d-$wday)*86400;
    my $timeString     = '{ my $date='."$date;" .$time."}";    
    my $eTimeString    = eval( $timeString );                            # must deliver HH:MM[:SS]
    if ($@) {
       $@ =~ s/\n/ /g; 
       Log3 ($hash, 3, "[$name] " . $@ . ">>>$timeString<<<");
       $eTimeString = "00:00:00";
    }
    
    if      ($eTimeString =~  m/^[0-2][0-9]:[0-5][0-9]$/g) {          #  HH:MM
      $eTimeString .= ":00";                                          #  HH:MM:SS erzeugen
    } elsif ($eTimeString =~  m/^[0-2][0-9](:[0-5][0-9]){2,2}$/g) {   #  HH:MM:SS
      ;                                                               #  ok.
    } else {
      Log3 ($hash, 1, "[$name] invalid time <$eTimeString> HH:MM[:SS]");
      $eTimeString = "00:00:00";
    }
    return $eTimeString;
}
################################################################################
sub WeekdayTimer_zeitErmitteln  ($$$$$) {
   my ($now, $hour, $min, $sec, $days) = @_;

   my @jetzt_arr = localtime($now);
   #Stunden               Minuten               Sekunden
   $jetzt_arr[2]  = $hour; $jetzt_arr[1] = $min; $jetzt_arr[0] = $sec;
   $jetzt_arr[3] += $days;
   my $next = timelocal_nocheck(@jetzt_arr);
   return $next;
}
################################################################################
sub WeekdayTimer_gatherSwitchingTimes {
  my $a = shift;

  my @switchingtimes = ();
  my $conditionOrCommand;
  
  # switchingtime einsammeln
  while (@$a > 0) {

    #pruefen auf Angabe eines Schaltpunktes
    my $element = shift @$a;
    my @t = split(/\|/, $element);
    my $anzahl = @t;
    if ( $anzahl >= 2 && $anzahl <= 3) {
      push(@switchingtimes, $element);
    } else {
      unshift @$a, $element; 
      last;
    }
  }
  return (@switchingtimes);
}    
################################################################################
sub WeekdayTimer_Language {
  my ($hash, $a) = @_;
    
  my $name = $hash->{NAME};  

  # ggf. language optional Parameter
  my $langRegExp = "(" . join ("|", keys(%{$hash->{shortDays}})) . ")";
  my $language   = shift @$a;

  if ($language =~  m/^$langRegExp$/g) {
  } else {
     Log3 ($hash, 3, "[$name] language: $language not recognized, use one of $langRegExp") if (length($language) == 2);
     unshift @$a, $language; 
     $language   = "de";
  }
  $hash->{LANGUAGE} = $language;

  $language = $hash->{LANGUAGE};
    return ($langRegExp, $language);
}
################################################################################
sub WeekdayTimer_GlobalDaylistSpec {
  my ($hash, $a) = @_;
    
  my $daylist = shift @$a;

  my @tage = @{WeekdayTimer_daylistAsArray($hash, $daylist)}; 
  my $tage = @tage; 
  if ($tage > 0) {
    ;
  } else {
    unshift (@$a,$daylist);     
    $daylist = "";
  }
  
  $hash->{GlobalDaylistSpec} = $daylist;
}
################################################################################
sub WeekdayTimer_SetTimerForMidnightUpdate($) {
    my ($myHash) = @_;
    my $hash = myGetHashIndirekt($myHash, (caller(0))[3]);
    return if (!defined($hash));

   my $now = time();
   my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($now);
   my $secToMidnight = 24*3600 -(3600*$hour + 60*$min + $sec) + 5;
  #my $secToMidnight =                                        + 01*60;

   myRemoveInternalTimer("SetTimerOfDay", $hash);
   myInternalTimer      ("SetTimerOfDay", $now+$secToMidnight, "$hash->{TYPE}_SetTimerOfDay", $hash, 0);

}
################################################################################
sub WeekdayTimer_SetTimerOfDay($) {
    my ($myHash) = @_;
    my $hash = myGetHashIndirekt($myHash, (caller(0))[3]);
    return if (!defined($hash));

    WeekdayTimer_DeleteTimer($hash);
    WeekdayTimer_Profile    ($hash);
    WeekdayTimer_SetTimer   ($hash);
    
    WeekdayTimer_SetTimerForMidnightUpdate( { HASH => $hash} );
}
################################################################################
sub WeekdayTimer_SetTimer($) {
  my $hash = shift; 
  my $name = $hash->{NAME};
  
  my $now  = time();  

  my $switchedInThePast = 0;
  my $isHeating     = WeekdayTimer_isHeizung($hash);
  my $grenzSeconds  = $isHeating ? -24*3600 : -5; 
  
  my @switches = sort keys %{$hash->{profil}};
  if ($#switches < 0) {
     Log3 $hash, 3, "[$name] no switches to send, due to possible errors.";
     return; 
  }   
  
  my $nextSwitch = $switches[0];
  my $nextPara   = $hash->{profil}{$switches[0]}{PARA};
  
  my @reverseSwitches = ((reverse @switches), $switches[$#switches]);
  for(my $i=0; $i<=$#reverseSwitches; $i++) {
     my $time = $reverseSwitches[$i];
  
     $hash->{profil}{$time}{NEXTPARA}   = $nextPara;
     $hash->{profil}{$time}{NEXTSWITCH} = $nextSwitch;
               
     my $timToSwitch = $hash->{profil}{$time}{TIM};
        $nextPara    = $hash->{profil}{$time}{PARA};
        $nextSwitch  = $time;
     
     $timToSwitch -= 24*3600 if ($i == $#reverseSwitches);
     my $secondsToSwitch = $timToSwitch - $now;
     
     if ($secondsToSwitch>$grenzSeconds && !$switchedInThePast) {    
       myInternalTimer       ("$time", $timToSwitch, "$hash->{TYPE}_Update", $hash, 0);
       $switchedInThePast = ($secondsToSwitch<0);
     }
  }     
}
################################################################################
sub WeekdayTimer_DeleteTimer($) {
  my $hash = shift; 
  map {myRemoveInternalTimer ($_, $hash)}      keys %{$hash->{profil}};
}
################################################################################
sub WeekdayTimer_Update($) {
  my ($myHash) = @_;
  my $hash = myGetHashIndirekt($myHash, (caller(0))[3]);
  return if (!defined($hash));

  my $name     = $hash->{NAME};
  my $time     = $myHash->{MODIFIER};
  my $now      = time();

  # Schaltparameter ermitteln
  my $tage        = $hash->{profil}{$time}{TAGE};
  my $newParam    = $hash->{profil}{$time}{PARA};
  my $nextSwitch  = $hash->{profil}{$time}{NEXTSWITCH};
  my $nextParam   = $hash->{profil}{$time}{NEXTPARA};

  # Fenserkontakte abfragen - wenn einer im Status closed, dann Schaltung um 60 Sekunden verzögern
  if (WeekdayTimer_FensterOffen($hash, $newParam, $time)) {
     return;
  }

  my $active = 1;
  my $condition = WeekdayTimer_Condition ($hash, $tage);
  if ($condition) {
     $active = AnalyzeCommandChain(undef, "{". $condition ."}");
  }
  Log3 $hash, 4, "[$name] seems to be active: $condition" if($active);

  # ggf. Device schalten
  WeekdayTimer_Device_Schalten($hash, $newParam, $tage);
    
  readingsBeginUpdate($hash);
  readingsBulkUpdate ($hash,  "nextUpdate", $nextSwitch);
  readingsBulkUpdate ($hash,  "nextUpdate", $nextSwitch);
  readingsBulkUpdate ($hash,  "nextValue",  $nextParam);
  readingsBulkUpdate ($hash,  "state",      $active ? $newParam : "inactive" );
  readingsEndUpdate  ($hash,  defined($hash->{LOCAL} ? 0 : 1));

  return 1; 
     
}
################################################################################
sub WeekdayTimer_isHeizung($) {
  my ($hash)  = @_;

  my %setmodifiers =
     ("FHT"     =>  "desired-temp",
      "PID20"   =>  "desired",
      "EnOcean" =>  {  "subTypeReading" => "subType", "setModifier" => "desired-temp",
                       "roomSensorControl.05"  => 1,
                       "hvac.01"               => 1 },
      "MAX"     =>  {  "subTypeReading" => "type", "setModifier" => "desiredTemperature",
                       "HeatingThermostatPlus" => 1,
                       "HeatingThermostat"     => 1,
                       "WallMountedThermostat" => 1 },
      "CUL_HM"  =>  {  "subTypeReading" => "model","setModifier" => "desired-temp",
                       "HM-CC-TC"              => 1,
                       "HM-TC-IT-WM-W-EU"      => 1,
                       "HM-CC-RT-DN"           => 1 } );
  my $dHash = $defs{$hash->{DEVICE}};                                           
  my $dType = $dHash->{TYPE};
  return ""   if (!defined($dType));

  my $setModifier = $setmodifiers{$dType};
     $setModifier = ""  if (!defined($setModifier));
  if (ref($setModifier)) {

      my $subTypeReading = $setmodifiers{$dType}{subTypeReading};
      
      my $model;
      if ($subTypeReading eq "type" ) {
         $model = $dHash->{type};
      } else {   
         $model = AttrVal($hash->{DEVICE}, $subTypeReading, "nF");
      }        
      
      if (defined($setmodifiers{$dType}{$model})) {
         $setModifier = $setmodifiers{$dType}{setModifier}
      } else {
         $setModifier = "";
      }
  }
  return $setModifier;
}
################################################################################
#
sub WeekdayTimer_FensterOffen ($$$) {
  my ($hash, $event, $time) = @_;
  my $name = $hash->{NAME};
  
  my $verzoegerteAusfuehrungCond = AttrVal($hash->{NAME}, "delayedExecutionCond", "0");

  my %specials= (
         "%HEATING_CONTROL"  => $hash->{NAME},
         "%WEEKDAYTIMER"     => $hash->{NAME},
         "%NAME"             => $hash->{DEVICE},
         "%EVENT"            => $event
  );
  $verzoegerteAusfuehrungCond = EvalSpecials($verzoegerteAusfuehrungCond, %specials);
  my $verzoegerteAusfuehrung = eval($verzoegerteAusfuehrungCond);
  
  if ($verzoegerteAusfuehrung) {
     if (!defined($hash->{VERZOEGRUNG})) {
        Log3 $hash, 3, "[$name] switch of $hash->{DEVICE} delayed - $verzoegerteAusfuehrungCond is TRUE";
     }
     myRemoveInternalTimer("Update", $hash);
     myInternalTimer      ("$time",  time()+60, "$hash->{TYPE}_Update", $hash, 0);
     $hash->{VERZOEGRUNG} = 1;
     return 1
  }
  
  my %contacts =  ( "CUL_FHTTK"       => { "READING" => "Window",          "STATUS" => "(Open)",        "MODEL" => "r" },
                    "CUL_HM"          => { "READING" => "state",           "STATUS" => "(open|tilted)", "MODEL" => "r" },
                    "MAX"             => { "READING" => "state",           "STATUS" => "(open)",        "MODEL" => "r" },
                    "WeekdayTimer"    => { "READING" => "delayedExecution","STATUS" => "^1\$",          "MODEL" => "a" },
                    "Heating_Control" => { "READING" => "delayedExecution","STATUS" => "^1\$",          "MODEL" => "a" }
                  );
                  
  my $fensterKontakte = AttrVal($hash->{NAME}, "windowSensor", "")." ".$hash->{NAME};
  $fensterKontakte =~ s/^\s+//;
  $fensterKontakte =~ s/\s+$//;
  
  Log3 $hash, 5, "[$name] list of window sensors found: '$fensterKontakte'";
  if ($fensterKontakte ne "" ) {
     my @kontakte = split("[ \t]+", $fensterKontakte);
     foreach my $fk (@kontakte) {
        if(!$defs{$fk}) {
           Log3 $hash, 3, "[$name] sensor <$fk> not found - check name.";
        } else {
           my $fk_hash = $defs{$fk};
           my $fk_typ  = $fk_hash->{TYPE};
           if (!defined($contacts{$fk_typ})) {
              Log3 $hash, 3, "[$name] TYPE '$fk_typ' of $fk not yet supported, $fk ignored - inform maintainer";
           } else {
           
              my $reading      = $contacts{$fk_typ}{READING};
              my $statusReg    = $contacts{$fk_typ}{STATUS};
              my $model        = $contacts{$fk_typ}{MODEL};
              
              my $windowStatus;
              if ($model eq "r")  {   ### Reading, sonst Attribut
                 $windowStatus = ReadingsVal($fk,$reading,"nF");
              }else{
                 $windowStatus = AttrVal    ($fk,$reading,"nF");              
              }
              
              if ($windowStatus eq "nF") {
                 Log3 $hash, 3, "[$name] Reading/Attribute '$reading' of $fk not found, $fk ignored - inform maintainer" if ($model eq "r");
              } else {
                 Log3 $hash, 5, "[$name] sensor '$fk' Reading/Attribute '$reading' is '$windowStatus'";

                 if ($windowStatus =~  m/^$statusReg$/g) {
                    if (!defined($hash->{VERZOEGRUNG})) {
                       Log3 $hash, 3, "[$name] switch of $hash->{DEVICE} delayed - sensor '$fk' Reading/Attribute '$reading' is '$windowStatus'";
                    }
					myRemoveInternalTimer("Update", $hash);
				   #myInternalTimer      ("Update", time()+60, "$hash->{TYPE}_Update", $hash, 0);
                    myInternalTimer      ("$time",  time()+60, "$hash->{TYPE}_Update", $hash, 0);
                    $hash->{VERZOEGRUNG} = 1;
                    return 1
                 }
              }
           }
        }
     }
  }
  if ($hash->{VERZOEGRUNG}) {
     Log3 $hash, 3, "[$name] delay of switching $hash->{DEVICE} stopped.";
  }
  delete $hash->{VERZOEGRUNG};
  return 0;
}
################################################################################
sub WeekdayTimer_Device_Schalten($$$) {
  my ($hash, $newParam, $tage)  = @_;

  my ($command, $condition) = "";
  my $name = $hash->{NAME};                                        ###

  my $now = time();
  #modifier des Zieldevices auswaehlen
  my $setModifier = WeekdayTimer_isHeizung($hash);
  
  $command = '{ fhem("set @ '. $setModifier .' %") }';
  $command = $hash->{COMMAND}               if (defined $hash->{COMMAND});

  $condition = WeekdayTimer_Condition($hash, $tage);
       
  $command = "{ if " .$condition . " " . $command . "}";

  my $isHeating = $setModifier gt "";
  my $aktParam  = ReadingsVal($hash->{DEVICE}, $setModifier, "");
     $aktParam  = sprintf("%.1f", $aktParam)   if ($isHeating && $aktParam =~ m/^[0-9]{1,3}$/i);
     $newParam  = sprintf("%.1f", $newParam)   if ($isHeating && $newParam =~ m/^[0-9]{1,3}$/i);

  my $disabled = AttrVal($hash->{NAME}, "disable", 0);
  my $disabled_txt = $disabled ? " " : " not";
  Log3 $hash, 5, "[$name] aktParam:$aktParam newParam:$newParam - is $disabled_txt disabled";

  #Kommando ausführen
  if ($command && !$disabled && $aktParam ne $newParam) {
    $newParam =~ s/:/ /g;

    $command  = SemicolonEscape($command);
    my %specials= (
           "%NAME"  => $hash->{DEVICE},
           "%EVENT" => $newParam,
    );
    $command= EvalSpecials($command, %specials);

    Log3 $hash, 4, "[$name] command: $command executed";
    my $ret  = AnalyzeCommandChain(undef, $command);
    Log3 ($hash, 3, $ret) if($ret);
  } 
}
################################################################################
sub WeekdayTimer_Condition($$) {  
  my ($hash, $tage)  = @_;
  
  my $condition  = "( ";
  $condition .= (defined $hash->{CONDITION}) ? $hash->{CONDITION}  : 1 ; 
  $condition .= " && " . WeekdayTimer_TageAsCondition($tage);
  $condition .= ")";
  
  return $condition;
  
}
################################################################################
sub WeekdayTimer_TageAsCondition ($) {
   my $tage = shift;
   
   my %days     = map {$_ => 1} @$tage;
    
   my $we       = $days{7}; delete $days{7};  # $we
   my $notWe    = $days{8}; delete $days{8};  #!$we
   
   my $tageExp  = '($wday ~~ [' . join (",", sort keys %days) . "]";
      $tageExp .= ' ||  $we' if defined $we; 
      $tageExp .= ' || !$we' if defined $notWe;
      $tageExp .= ')';
      
   return $tageExp;
   
}
################################################################################
sub WeekdayTimer_Attr($$$) {
  my ($cmd, $name, $attrName, $attrVal) = @_;

  if( $attrName eq "disable" ) {
     my $hash = $defs{$name};
     readingsSingleUpdate ($hash,  "disabled",  $attrVal, 1);
  }
  return undef;
}
################################################################################
sub WeekdayTimer_SetAllParms() {            # {WeekdayTimer_SetAllParms()}

  foreach my $hc ( sort keys %{$modules{WeekdayTimer}{defptr}} ) {
     my $hash = $modules{WeekdayTimer}{defptr}{$hc};

     WeekdayTimer_SetTimer($hash);
     Log3 undef, 3, "WeekdayTimer_SetAllParms() for $hash->{NAME} done!";
  }
  Log3 undef,  3, "WeekdayTimer_SetAllParms() done!";
}

1;

=pod
=begin html

<a name="WeekdayTimer"></a>
<meta content="text/html; charset=ISO-8859-1" http-equiv="content-type">
<h3>WeekdayTimer</h3>
<ul>
  <br>
  <a name="weekdayTimer_define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; WeekdayTimer &lt;device&gt; &lt;profile&gt; &lt;command&gt;|&lt;condition&gt;</code>
    <br><br>

    to set a weekly profile for &lt;device&gt;<br><br>

    You can define different switchingtimes for every day.<br>
    The new parameter is sent to the &lt;device&gt; automatically with <br><br>

    <code>set &lt;device&gt; &lt;para&gt;</code><br><br>

    If you have defined a &lt;condition&gt; and this condition is false if the switchingtime has reached, no command will executed.<br>
    An other case is to define an own perl command with &lt;command&gt;.
    <p>
    The following parameter are defined:
    <ul><b>device</b><br>
      The device to switch at the given time.
    </ul>
    <p>
    <ul><b>profile</b><br>
      Define the weekly profile. All timings are separated by space. A switchingtime is defined by the following example:<br>
      <ul><b>[&lt;weekdays&gt;|]&lt;time&gt;|&lt;parameter&gt;</b></ul><br>
      <u>weekdays:</u> optional, if not set every day is used. Otherwise you can define a day as a number or as shortname.<br>
      <u>time:</u>define the time to switch, format: HH:MM(HH in 24 hour format). Within the {} you can use the variable $date(epoch) to get the exact switchingtimes of the week. Example: {sunrise_abs_dat($date)}<br>
      <u>parameter:</u>the parameter to be set, using any text value like <b>on</b>, <b>off</b>, <b>dim30%</b>, <b>eco</b> or <b>comfort</b> - whatever your device understands.<br>
    </ul>
    <p>
    <ul><b>command</b><br>
      If no condition is set, all other is interpreted as a command. Perl-code is setting up
      by well-known Block with {}.<br>
      Note: if a command is defined only this command is executed. In case of executing
      a "set desired-temp" command, you must define it explicit.<br>
      The following parameter are replaced:<br>
        <ol>
          <li>@ => the device to switch</li>
          <li>% => the new parameter</li>
        </ol>
    </ul>
    <p>
    <ul><b>condition</b><br>
      if a condition is defined you must declared this with () and a valid perl-code.<br>
      The return value must be boolean.<br>
      The parameter @ and % will be interpreted.
    </ul>
    <p>
    <b>Example:</b>
    <ul>
        <code>define shutter WeekdayTimer bath 12345|05:20|up  12345|20:30|down</code><br>
        Mo-Fr are setting the shutter at 05:20 to <b>up</b>, and at 20:30 <b>down</b>.<p>

        <code>define heatingBath WeekdayTimer bath 07:00|16 Mo,Tu,Th-Fr|16:00|18.5 20:00|eco
          {fhem("set dummy on"); fhem("set @ desired-temp %");}</code><br>
        At the given times and weekdays only(!) the command will be executed.<p>

        <code>define dimmer WeekdayTimer livingRoom Sa-Su,We|07:00|dim30% Sa-Su,We|21:00|dim90% (ReadingsVal("WeAreThere", "state", "no") eq "yes")</code><br>
        The dimmer is only set to dimXX% if the dummy variable WeAreThere is "yes"(not a real live example).<p>

        If you want to have set all WeekdayTimer their current value (after a phase of exception),
        you can call the function <b> WeekdayTimer_SetAllParms ()</b>.
        This call can be automatically coupled to a dummy by notify:
        <code>define WDStatus2 notify Dummy:. * {WeekdayTimer_SetAllParms ()}</code>

    </ul>
  </ul>

  <a name="WeekdayTimerset"></a>
  <b>Set</b>

    <code><b><font size="+1">set &lt;name&gt; &lt;value&gt;</font></b></code>
    <br><br>
    where <code>value</code> is one of:<br>
    <pre>
    <b>disable</b>               # disables the Weekday_Timer
    <b>enable</b>                # enables  the Weekday_Timer
    </pre>

    <b><font size="+1">Examples</font></b>:
    <ul>
      <code>set wd disable</code><br>
      <code>set wd enable</code><br>
    </ul>
  </ul>  

  <a name="WeekdayTimerget"></a>
  <b>Get</b> <ul>N/A</ul><br>

  <a name="WeekdayTimerLogattr"></a>
  <b>Attributes</b>
  <ul>
    <li>delayedExecutionCond <br> 
    defines a delay Function. When returning true, the switching of the device is delayed until the function retruns a false value. The behavior is just like a windowsensor in Heating_Control.
    
    <br><br>
    <b>Example:</b>    
    <pre>
    attr wd delayedExecutionCond isDelayed("%HEATING_CONTROL","%WEEKDAYTIMER","%TIME","%NAME","%EVENT")  
    </pre>
    the parameter %WEEKDAYTIMER(timer name) %TIME %NAME(device name) %EVENT are replaced at runtime by the correct value.
    
    <br><br>
    <b>Example of a function:</b>    
    <pre>
    sub isDelayed($$$$$) {
       my($hc, $wdt, $tim, $nam, $event ) = @_;
       
       my $theSunIsStillshining = ...
    
       return ($tim eq "16:30" && $theSunIsStillshining) ;    
    }
    </pre>    
    </li>
    
    <li><a href="#disable">disable</a></li>
    <li><a href="#loglevel">loglevel</a></li>
    <li><a href="#event-on-update-reading">event-on-update-reading</a></li>
    <li><a href="#event-on-change-reading">event-on-change-reading</a></li>
    <li><a href="#stateFormat">stateFormat</a></li>
  </ul><br>


=end html

=cut