function [trackResults, channel]= tracking(fid, channel, settings)
// Performs code and carrier tracking for all channels.
//
//[trackResults, channel] = tracking(fid, channel, settings)
//
//   Inputs:
//       fid             - file identifier of the signal record.
//       channel         - PRN, carrier frequencies and code phases of all
//                       satellites to be tracked (prepared by preRum.m from
//                       acquisition results).
//       settings        - receiver settings.
//   Outputs:
//       trackResults    - tracking results (structure array). Contains
//                       in-phase prompt outputs and absolute spreading
//                       code's starting positions, together with other
//                       observation data from the tracking loops. All are
//                       saved every millisecond.

//--------------------------------------------------------------------------
//                           SoftGNSS v3.0
// 
// Copyright (C) Dennis M. Akos
// Written by Darius Plausinaitis and Dennis M. Akos
// Based on code by DMAkos Oct-1999
// Updated and converted to scilab 5.3.0 by Artyom Gavrilov
//--------------------------------------------------------------------------
//This program is free software; you can redistribute it and/or
//modify it under the terms of the GNU General Public License
//as published by the Free Software Foundation; either version 2
//of the License, or (at your option) any later version.
//
//This program is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU General Public License for more details.
//
//You should have received a copy of the GNU General Public License
//along with this program; if not, write to the Free Software
//Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
//USA.
//--------------------------------------------------------------------------

// Initialize result structure ============================================

  // Channel status
  trackResults.status         = '-';      // No tracked signal, or lost lock
  
  // The absolute sample in the record of the C/A code start:
  trackResults.absoluteSample = zeros(1, settings.msToProcess);
  
  // Freq of the C/A code:
  trackResults.codeFreq       = ones(1, settings.msToProcess).*%inf;
  
  // Frequency of the tracked carrier wave:
  trackResults.carrFreq       = ones(1, settings.msToProcess).*%inf;
  
  //Pilot-channel:
  // Outputs from the correlators (In-phase):
  trackResults.I_P            = zeros(1, settings.msToProcess);
  trackResults.I_E            = zeros(1, settings.msToProcess);
  trackResults.I_L            = zeros(1, settings.msToProcess);
  
  // Outputs from the correlators (Quadrature-phase):
  trackResults.Q_E            = zeros(1, settings.msToProcess);
  trackResults.Q_P            = zeros(1, settings.msToProcess);
  trackResults.Q_L            = zeros(1, settings.msToProcess);
  
  //Data-channel:
  // Outputs from the correlators (In-phase):
  trackResults.I_P2            = zeros(1, settings.msToProcess);
  trackResults.I_E2            = zeros(1, settings.msToProcess);
  trackResults.I_L2            = zeros(1, settings.msToProcess);
  
  // Outputs from the correlators (Quadrature-phase):
  trackResults.Q_E2            = zeros(1, settings.msToProcess);
  trackResults.Q_P2            = zeros(1, settings.msToProcess);
  trackResults.Q_L2            = zeros(1, settings.msToProcess);

  // Loop discriminators
  trackResults.dllDiscr       = ones(1, settings.msToProcess).*%inf;
  trackResults.dllDiscrFilt   = ones(1, settings.msToProcess).*%inf;
  trackResults.pllDiscr       = ones(1, settings.msToProcess).*%inf;
  trackResults.pllDiscrFilt   = ones(1, settings.msToProcess).*%inf;

  //--- Copy initial settings for all channels -------------------------------
  if settings.numberOfChannels > 0 then
    trackResults_tmp = trackResults;
    for i=2:settings.numberOfChannels
      trackResults_tmp = [trackResults_tmp trackResults];
    end;
    trackResults = trackResults_tmp;
    clear trackResults_tmp;  
  else
    clear trackResults;
  end;
  
  // Initialize tracking variables ==========================================
  
  codePeriods = settings.msToProcess;     // For GLONASS one CA code is one ms
  
  // CodeLength:
  settings_codeLength           = settings.codeLength;
  
  // Normal or switched IQ signal record:
  settings_switchIQ             = settings.switchIQ;
  
  // Nominal IF frequency:
  settings_IF                   = settings.IF;
  
  // Nominal code frequency:
  settings_codeFreqBasis        = settings.codeFreqBasis;
  
  // Nominal rf frequency for GLONASS L3:
  settings_GLONASS_nominal_freq = settings.GLONASS_nominal_freq;
  
  // Current sample number (of the signal from file):
  currentSample                 = 0;
  
  // Data type size in bytes of samples from gnss file record:
  settings_dataTypeSizeInBytes = settings.dataTypeSizeInBytes
  
  //--- DLL variables --------------------------------------------------------
  // Define early-late offset (in chips)
  earlyLateSpc = settings.dllCorrelatorSpacing;
  
  // Summation interval
  PDIcode = 0.001;
  
  // Calculate filter coefficient values
  [tau1code, tau2code] = calcLoopCoef(settings.dllNoiseBandwidth, ...
                                      settings.dllDampingRatio, ...
                                      1.0);
  
  //--- PLL variables --------------------------------------------------------
  // Summation interval
  PDIcarr = 0.001;
  
  // Calculate filter coefficient values
  [k1 k2 k3] = calcFLLPLLLoopCoef(settings.pllNoiseBandwidth, ...
                                 settings.fllNoiseBandwidth, PDIcarr);
  
  hwb = waitbar(0,'Tracking...');
  
  //Will we work with I-only data or IQ data.
  if (settings.fileType==1)
    dataAdaptCoeff=1;
  else
    dataAdaptCoeff=2;
  end

  // Start processing channels ==============================================
  for channelNr = 1:settings.numberOfChannels
    
    // Only process if PRN is non zero (acquisition was successful)
    if (channel(channelNr).PRN ~= 0)
      // Save additional information - each channel's tracked PRN
      trackResults(channelNr).PRN     = channel(channelNr).PRN;
        
      // Move the starting point of processing. Can be used to start the
      // signal processing at any point in the data record (e.g. for long
      // records). In addition skip through that data file to start at the
      // appropriate sample (corresponding to code phase). Assumes sample
      // type is schar (or 1 byte per sample) 
      mseek(dataAdaptCoeff*...
            (settings.skipNumberOfBytes + ...
             settings.dataTypeSizeInBytes*(channel(channelNr).codePhase-1)), fid);
      currentSample = dataAdaptCoeff*...
            (settings.skipNumberOfBytes + ...
             settings.dataTypeSizeInBytes*(channel(channelNr).codePhase-1));

      // Get a vector with the C/A code sampled 1x/chip
      caCode = generateCAcode(channel(channelNr).PRN);
      // Then make it possible to do early and late versions
      caCode = [caCode($) caCode caCode(1)];
      
      // C/A for data-channel:
      caCode2 = generateCAcode(channel(channelNr).PRN + 32);
      // Then make it possible to do early and late versions
      caCode2 = [caCode2($) caCode2 caCode2(1)];
      
      //--- Perform various initializations ------------------------------
      
      // define initial code frequency basis of NCO
      codeFreq      = settings_codeFreqBasis +..
                       ( (channel(channelNr).acquiredFreq - settings_IF) / ..
                       (settings_GLONASS_nominal_freq/settings_codeFreqBasis) )*0;
      // define residual code phase (in chips)
      remCodePhase  = 0.0;
      // define carrier frequency which is used over whole tracking period
      carrFreq      = channel(channelNr).acquiredFreq;
      carrFreqBasis = channel(channelNr).acquiredFreq;
      // define residual carrier phase
      remCarrPhase  = 0.0;
      
      //code tracking loop parameters
      oldCodeNco   = 0.0;
      oldCodeError = 0.0;
      
      //carrier/Costas loop parameters
      oldCarrNco   = 0.0;
      oldCarrError = 0.0;
      
      //frequency lock loop parameters
      oldFreqNco   = 0.0;
      oldFreqError = 0.0;
      
      //explain this!
      I1 = 0.001; I2 = 0.001; Q1 = 0.001; Q2 = 0.001;
      
      //temp variables! We have to use them in order to speed up the code!
      //Structs are extemly slow in scilab 5.3.0 :(
      loopCnt_carrFreq       = ones(1,  settings.msToProcess);
      loopCnt_codeFreq       = ones(1,  settings.msToProcess);
      loopCnt_absoluteSample = zeros(1, settings.msToProcess);
      loopCnt_dllDiscr       = ones(1,  settings.msToProcess);
      loopCnt_dllDiscrFilt   = ones(1,  settings.msToProcess);
      loopCnt_pllDiscr       = ones(1,  settings.msToProcess);
      loopCnt_pllDiscrFilt   = ones(1,  settings.msToProcess);
      //pilot channel:
      loopCnt_I_E            = zeros(1, settings.msToProcess);
      loopCnt_I_P            = zeros(1, settings.msToProcess);
      loopCnt_I_L            = zeros(1, settings.msToProcess);
      loopCnt_Q_E            = zeros(1, settings.msToProcess);
      loopCnt_Q_P            = zeros(1, settings.msToProcess);
      loopCnt_Q_L            = zeros(1, settings.msToProcess);
      //Data channel:
      loopCnt_I_E2            = zeros(1, settings.msToProcess);
      loopCnt_I_P2            = zeros(1, settings.msToProcess);
      loopCnt_I_L2            = zeros(1, settings.msToProcess);
      loopCnt_Q_E2            = zeros(1, settings.msToProcess);
      loopCnt_Q_P2            = zeros(1, settings.msToProcess);
      loopCnt_Q_L2            = zeros(1, settings.msToProcess);
      
      loopCnt_samplingFreq     = settings.samplingFreq;
      loopCnt_codeLength       = settings.codeLength;
      loopCnt_dataType         = settings.dataType;
      loopCnt_codeFreqBasis    = settings.codeFreqBasis;
      loopCnt_numberOfChannels = settings.numberOfChannels
      
      //=== Process the number of specified code periods =================
      for loopCnt =  1:codePeriods
        
        // GUI update ---------------------------------------------------------
        // The GUI is updated every 50ms.
        if (  (loopCnt-fix(loopCnt/50)*50) == 0  )
        //Should be corrected in future! Doesn't work like original version :(
          try
            wbrMsg = strcat(['Tracking: Ch ' string(channelNr) ' of ' ...
                            string(loopCnt_numberOfChannels) '; PRN#' ...
                            string(channel(channelNr).PRN)]);
            waitbar(loopCnt/codePeriods, wbrMsg, hwb); 
          catch
            // The progress bar was closed. It is used as a signal
            // to stop, "cancel" processing. Exit.
            disp('Progress bar closed, exiting...');
            return
          end
        end

// Read next block of data ------------------------------------------------            
        // Find the size of a "block" or code period in whole samples
        
        // Update the phasestep based on code freq (variable) and
        // sampling frequency (fixed)
        codePhaseStep = codeFreq / loopCnt_samplingFreq;
        
        blksize = ceil((loopCnt_codeLength-remCodePhase) / codePhaseStep);
        
        // Read in the appropriate number of samples to process this
        // interation 
        rawSignal = mget(dataAdaptCoeff*blksize, loopCnt_dataType, fid);
        samplesRead = length(rawSignal);
        currentSample = currentSample + settings_dataTypeSizeInBytes*dataAdaptCoeff*blksize;
 
        if (dataAdaptCoeff==2)
          rawSignal1 = rawSignal(1:2:$);
          rawSignal2 = rawSignal(2:2:$);
          if (settings_switchIQ) then
              rawSignal = rawSignal2 + %i .* rawSignal1;
          else
              rawSignal = rawSignal1 + %i .* rawSignal2;
          end
        end
            
            
        // If did not read in enough samples, then could be out of 
        // data - better exit 
        if (samplesRead ~= dataAdaptCoeff*blksize)
          disp('Not able to read the specified number of samples  for tracking, exiting!')
          mclose(fid);
          return
        end

// Set up all the code phase tracking information -------------------------
        // Define index into early code vector
        tcode       = (remCodePhase-earlyLateSpc) : ...
                       codePhaseStep : ...
                       ((blksize-1)*codePhaseStep+remCodePhase-earlyLateSpc);
        tcode2      = ceil(tcode) + 1;
        earlyCode   = caCode(tcode2);
        earlyCode2   = caCode2(tcode2);
        
        // Define index into late code vector
        tcode       = (remCodePhase+earlyLateSpc) : ...
                       codePhaseStep : ...
                       ((blksize-1)*codePhaseStep+remCodePhase+earlyLateSpc);
        tcode2      = ceil(tcode) + 1;
        lateCode    = caCode(tcode2);
        lateCode2    = caCode2(tcode2);
        
        // Define index into prompt code vector
        tcode       = remCodePhase : ...
                      codePhaseStep : ...
                      ((blksize-1)*codePhaseStep+remCodePhase);
        tcode2      = ceil(tcode) + 1;
        promptCode  = caCode(tcode2);
        promptCode2  = caCode2(tcode2);
        
        remCodePhase = (tcode(blksize) + codePhaseStep) - loopCnt_codeLength;
        
// Generate the carrier frequency to mix the signal to baseband -----------
        time    = (0:blksize) ./ loopCnt_samplingFreq;
        
        // Get the argument to sin/cos functions
        trigarg = ((carrFreq * 2.0 * %pi) .* time) + remCarrPhase;
        remCarrPhase = trigarg(blksize+1) - ...
                        fix(trigarg(blksize+1)./(2 * %pi)).*(2 * %pi);
        
        // Finally compute the signal to mix the collected data to
        // bandband
        carrsig = exp(%i .* trigarg(1:blksize));
        
// Generate the six standard accumulated values ---------------------------
        // First mix to baseband
        qBasebandSignal = real(carrsig .* rawSignal);
        iBasebandSignal = imag(carrsig .* rawSignal);
        
        // Now get early, late, and prompt values for each
        I_E = sum(earlyCode  .* iBasebandSignal);
        Q_E = sum(earlyCode  .* qBasebandSignal);
        I_P = sum(promptCode .* iBasebandSignal);
        Q_P = sum(promptCode .* qBasebandSignal);
        I_L = sum(lateCode   .* iBasebandSignal);
        Q_L = sum(lateCode   .* qBasebandSignal);
        
        I_E2 = sum(earlyCode2  .* iBasebandSignal);
        Q_E2 = sum(earlyCode2  .* qBasebandSignal);
        I_P2 = sum(promptCode2 .* iBasebandSignal);
        Q_P2 = sum(promptCode2 .* qBasebandSignal);
        I_L2 = sum(lateCode2   .* iBasebandSignal);
        Q_L2 = sum(lateCode2   .* qBasebandSignal);
        
// Find combined PLL/FLL error and update carrier NCO (FLL-assisted PLL) ------
        I2 = I1;  Q2 = Q1;
        I1 = I_P2; Q1 = Q_P2;
        cross = I1*Q2 - I2*Q1;
        dot   = abs(I1*I2 + Q1*Q2);
        
        // Implement carrier loop discriminator (frequency detector)
        //freqError = atan(cross, dot)/(2*%pi)/0.001/500; //0.001 - integration periode. 
                                                          //500 - maximum discriminator output.
        freqError = atan(cross, dot) / %pi;  //normalized output in the range from -1 to +1.
        
        // Implement carrier loop discriminator (phase detector)
        carrError = atan(Q_P / I_P) / (2.0 * %pi);
        
        //Implement carrier loop filter and generate NCO command; 
        carrNco = oldCarrNco + k1*carrError - k2*oldCarrError + k3*freqError;
        
        oldCarrNco = carrNco;
        oldCarrError = carrError;
        
        carrFreq = carrFreqBasis + carrNco;
        
        loopCnt_carrFreq(loopCnt) = carrFreq;

// Find DLL error and update code NCO -------------------------------------
        codeError = (sqrt(I_E2 * I_E2 + Q_E2 * Q_E2) -...
                     sqrt(I_L2 * I_L2 + Q_L2 * Q_L2)) / ...
                    (sqrt(I_E2 * I_E2 + Q_E2 * Q_E2) +...
                     sqrt(I_L2 * I_L2 + Q_L2 * Q_L2));
        
        // Implement code loop filter and generate NCO command
        codeNco = oldCodeNco + (tau2code/tau1code) * ...
                  (codeError - oldCodeError) + codeError * (PDIcode/tau1code);
        oldCodeNco   = codeNco;
        oldCodeError = codeError;
        
        // Modify code freq based on NCO command
        codeFreq = loopCnt_codeFreqBasis - codeNco + ...
                       ( (carrFreq - settings_IF)/ ..
                       (settings_GLONASS_nominal_freq/settings_codeFreqBasis) );
        
        loopCnt_codeFreq(loopCnt) = codeFreq;
        
// Record various measures to show in postprocessing ----------------------
        // Record sample number (based on 8bit samples)
        ///loopCnt_absoluteSample(loopCnt) =(mtell(fid))/dataAdaptCoeff - ...
        ///                                  remCodePhase * ...
        ///                                  (loopCnt_samplingFreq/1000)/settings_codeLength;
        loopCnt_absoluteSample(loopCnt)= currentSample/dataAdaptCoeff - ...
                                          remCodePhase * ...
                                          (loopCnt_samplingFreq/1000)/settings_codeLength;
        
        loopCnt_dllDiscr(loopCnt)       = codeError;
        loopCnt_dllDiscrFilt(loopCnt)   = codeNco;
        loopCnt_pllDiscr(loopCnt)       = carrError;
        loopCnt_pllDiscrFilt(loopCnt)   = carrNco;
        
        loopCnt_I_E(loopCnt) = I_E;
        loopCnt_I_P(loopCnt) = I_P;
        loopCnt_I_L(loopCnt) = I_L;
        loopCnt_Q_E(loopCnt) = Q_E;
        loopCnt_Q_P(loopCnt) = Q_P;
        loopCnt_Q_L(loopCnt) = Q_L;
        
        loopCnt_I_E2(loopCnt) = I_E2;
        loopCnt_I_P2(loopCnt) = I_P2;
        loopCnt_I_L2(loopCnt) = I_L2;
        loopCnt_Q_E2(loopCnt) = Q_E2;
        loopCnt_Q_P2(loopCnt) = Q_P2;
        loopCnt_Q_L2(loopCnt) = Q_L2;
      end // for loopCnt

      // If we got so far, this means that the tracking was successful
      // Now we only copy status, but it can be update by a lock detector
      // if implemented
      trackResults(channelNr).status  = channel(channelNr).status;
      
      //Now copy all data from temp variable to the real place! 
      //We do it to speed up the code.
      trackResults(channelNr).carrFreq       = loopCnt_carrFreq;
      trackResults(channelNr).codeFreq       = loopCnt_codeFreq;
      trackResults(channelNr).absoluteSample = loopCnt_absoluteSample;
      trackResults(channelNr).dllDiscr       = loopCnt_dllDiscr;
      trackResults(channelNr).dllDiscrFilt   = loopCnt_dllDiscrFilt;
      trackResults(channelNr).pllDiscr       = loopCnt_pllDiscr;
      trackResults(channelNr).pllDiscrFilt   = loopCnt_pllDiscrFilt;
      trackResults(channelNr).I_E            = loopCnt_I_E;
      trackResults(channelNr).I_P            = loopCnt_I_P;
      trackResults(channelNr).I_L            = loopCnt_I_L;
      trackResults(channelNr).Q_E            = loopCnt_Q_E;
      trackResults(channelNr).Q_P            = loopCnt_Q_P;
      trackResults(channelNr).Q_L            = loopCnt_Q_L;
      
      trackResults(channelNr).I_E2            = loopCnt_I_E2;
      trackResults(channelNr).I_P2            = loopCnt_I_P2;
      trackResults(channelNr).I_L2            = loopCnt_I_L2;
      trackResults(channelNr).Q_E2            = loopCnt_Q_E2;
      trackResults(channelNr).Q_P2            = loopCnt_Q_P2;
      trackResults(channelNr).Q_L2            = loopCnt_Q_L2;
      
    end // if a PRN is assigned
    
end // for channelNr 

// Close the waitbar
winclose(hwb)

endfunction
