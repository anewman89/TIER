function metPoint = calcPrecip(parameters,gridElev,defaultSlope,finalWeights,finalWeightsAspect,symapWeights,stationElevNear,stationElevAspect,stationVarNear,stationVarAspect)
%
%% calcPrcp computes the first pass STIR estimate of precipitation
%
% Summary: This algorithm generally follows Daly et al. (1994,2002,2007,2008) and
% others.  However, here the regression estimated parameters
% and the grid point elevation to compute the precipitation is not done.
% Instead, the SYMAP estimate is used at all grid points as the intercept
% and the weighted linear regression slope is used to adjust the SYMAP
% estimate up or down based on the elevation difference between the grid
% and the SYMAP weighted station elevation.  This approach gives similar
% results and is effectively an elevation adjustment to a SYMAP estimate
% where the SYMAP weights here are computed using all knowledge based
% terms in addition to the SYMAP distance & angular isolation weights
% Other modifications from the above cited papers are present and
% summarized below.
   

% Specific modifications/notes for initial precipitation implementation 
% (eq. 2, Daly et al. 2002):
% 1) Here there are only 4-directional facets and flat (see stirPreprocessing.m for details)
%    1 = N
%    2 = E
%    3 = S
%    4 = W
%    5 = Flat
% 2) no elevation weighting factor
% 3) cluster weighting factor using symap type weighting
% 4) no topographic facet weighting factor

% 5) number of stations and facet weighting:
% the nMaxNear nearest stations are always used to determine the base
% precip value, then only stations on the correct facet are
% used to determine the elevation-variable relationship (slope).  
% facet weighting where stations on same facet but with other facets 
% inbetween get less weight is not considered.  All stations on the same 
% facet get the same "facet" weight
% 6) default lapse rates are updated after first pass to remove the
% spatially constant default lapse rate constraint (updatePrecipSlope.m)
%
%
% Author: Andrew Newman NCAR/RAL
% Email : anewman@ucar.edu
%
% Arguments:
%
%  Input:
%
%   parameters  , structure, structure holding all STIR parameters
%   gridElev    , float    , elevation of current grid point
%   defaultSlope, float    , default normalized precipitation slope at
%                            current grid point as current grid point
%   finalWeights,       float, station weights for nearby stations
%   finalWeightsAspect, float, station weights for nearby stations on same
%                              slope aspect
%   symapWeights,      float , symap station weights for nearby stations
%   stationElevNear,   float , station elevations for nearby stations
%   stationElevAspect, float , station elevations for nearby stations on
%                              same slope aspect as current grid point
%   stationVarNear   , float , station values for nearby stations
%   stationVarAspect , float , sataion values for nearby stations on same 
%                              slope aspect as current grid point
%
%  Output:
%
%   metPoint, structure, structure housing all grids related to
%                        precipitation for the current grid point
%
%
    %define tiny
    tiny = 1e-15;
    %define large;
    large = 1e15;
    
    %set local min station parameter
    nMinNear = parameters.nMinNear;
    
    %local slope values
    minSlope = parameters.minSlope;
    maxSlope = parameters.maxInitialSlope;

    %initalize metPoint structure
    metPoint.rawField        = NaN;
    metPoint.intercept       = NaN;
    metPoint.slope           = NaN;
    metPoint.normSlope       = NaN;
    metPoint.symapField      = NaN;
    metPoint.symapElev       = NaN;
    metPoint.symapUncert     = NaN;
    metPoint.slopeUncert     = NaN;
    metPoint.normSlopeUncert = NaN;
    metPoint.intercept       = NaN;
    metPoint.validRegress    = NaN;
    
    %first estimate the 'SYMAP' value at grid point, but use full knowledge
    %based weights if possible. this serves as the base estimate with no 
    %weighted linear elevation regression
   
    %if the final weight vector is invalid, default to symap weights only
    if(isnan(finalWeights(1)))
        %compute SYMAP precipitaiton
        metPoint.symapField = sum(symapWeights.*stationVarNear)/sum(symapWeights);
        %compute mean elevation of SYMAP stations
        metPoint.symapElev = sum(symapWeights.*stationElevNear)/sum(symapWeights);
        %estimate uncertainty using standard deviation of leave-one-out
        %estimates
        nsta = length(symapWeights);
        combs = nchoosek(1:nsta,nsta-1);
        metPoint.symapUncert = std(sum(symapWeights(combs).*stationVarNear(combs),2)./sum(symapWeights(combs),2));
    else %estimate simple average using final weights
        metPoint.symapField = sum(finalWeights.*stationVarNear)/sum(finalWeights);
        metPoint.symapElev = sum(finalWeights.*stationElevNear)/sum(finalWeights);
        %estimate uncertainty using standard deviation of leave-one-out
        %estimates
        nsta = length(symapWeights);
        combs = nchoosek(1:nsta,nsta-1);
        metPoint.symapUncert = std(sum(finalWeights(combs).*stationVarNear(combs),2)./sum(finalWeights(combs),2));
    end

    %if there are more than nMinNear stations, proceed with
    %weighted elevation regression
    if(length(stationElevAspect) >= nMinNear)
        %create weighted linear regression relationship
        linFit = calcWeightedRegression(stationElevAspect,stationVarAspect,finalWeightsAspect);
        %define normalized slope estimate
        elevSlope = linFit(1)/mean(stationVarAspect);
        
        %Run through station combinations and find outliers to see if we
        %can get a valid met var - elevation slope
        if(elevSlope < minSlope || elevSlope > maxSlope)
            %number of stations considered on current grid point aspect
            nSta = length(stationVarAspect);
            %variable to track slope changes when estimating slope in
            %weighted regression
            maxSlopeDelta = 0;

            %set combinations for the number of combinations possbile 
            %selecting nSta-1 stations given nSta stations
            combs = nchoosek(1:nSta,nSta-1);
            %counter to track number of valid slopes
            cnt = 1;
            %initalize variable to hold valid slopes
            combSlp = zeros(1,1);
            %step through combinations
            for c = 1:length(combs(:,1))
                %define station attributes matrix (X) for regression 
                X = [ones(size(stationElevAspect(combs(c,:)))) stationElevAspect(combs(c,:))];

                %if X is square
                if(size(X,1)==size(X,2))
                    %if well conditioned
                    if(rcond(X)>tiny)
                        %compute weighted regression
                        tmpLinFit = calcWeightedRegression(stationElevAspect(combs(c,:)),stationVarAspect(combs(c,:)),...
                                                           finalWeightsAspect(combs(c,:)));
                        %set normalized slope variable
                        elevSlopeTest = tmpLinFit(1)/mean(stationVarAspect(combs(c,:)));
                        %compute change in slope from initial estimate
                        slopeDelta = abs(elevSlope - elevSlopeTest);
                    else %if X not well conditioned, set to unrealistic values
                        elevSlopeTest = large;
                        slopeDelta = -large;
                    end
                else
                    %compute weighted regression
                    tmpLinFit = calcWeightedRegression(stationElevAspect(combs(c,:)),stationVarAspect(combs(c,:)),...
                                                       finalWeightsAspect(combs(c,:)));
                    %set normalized slope variable
                    elevSlopeTest = tmpLinFit(1)/mean(stationVarAspect(combs(c,:)));
                    %compute change in slope from initial estimate
                    slopeDelta = abs(elevSlope - elevSlopeTest);
                end
                %if the recomputed slope is valid and has the largest slope
                %change, this specific case is the best estimate removing
                %the largest outlier in terms of estimated slope
                if(elevSlopeTest > minSlope && elevSlopeTest < maxSlope && slopeDelta > maxSlopeDelta)
                    removeOutlierInds = combs(c,:);
                    maxSlopeDelta = slopeDelta;
                    %add valid slope to vector
                    combSlp(cnt) = elevSlopeTest;
                    %increment counter
                    cnt = cnt + 1;
                %catch the rest of the recomputed slopes that are valid
                elseif(elevSlopeTest > minSlope && elevSlopeTest < maxSlope)
                    %add valid slope to vector
                    combSlp(cnt) = elevSlopeTest;
                    %increment counter
                    cnt = cnt + 1;
                end
            end %end of combination loop
                
            %if two or more valid combination of stations
            %estimate uncertainty of slope at grid point using standard
            %deviation of estimates
            if(cnt > 2)
                metPoint.normSlopeUncert = std(combSlp);                
            end
            
            %if there was a valid outlier removal combination, use the 
            %'best' combination
            if(maxSlopeDelta>0)
                %compute regression estimate
                linFit = calcWeightedRegression(stationElevAspect(removeOutlierInds),stationVarAspect(removeOutlierInds),...
                                                finalWeightsAspect(removeOutlierInds));
                
                %override the regression intercept with the symap estimate
                linFit(2) = metPoint.symapField;
                
                if(isnan(linFit(1)))
                    linFit(1) = defaultSlope*metPoint.symapField;
                    tmpField = polyval(linFit,gridElev-metPoint.symapElev);
                else
                    tmpField = polyval(linFit,gridElev-metPoint.symapElev);
                end
                metPoint.rawField = tmpField;
                metPoint.slope = linFit(1);
                metPoint.normSlope = linFit(1)/mean(stationVarAspect(removeOutlierInds));
                metPoint.intercept = linFit(2);
                metPoint.validRegress = 1;
            else
                linFit(1) = defaultSlope*metPoint.symapField;
                linFit(2) = metPoint.symapField;
                
                metPoint.rawField = polyval(linFit,gridElev-metPoint.symapElev);
                metPoint.normSlope  = linFit(1)/mean(stationVarAspect);
                metPoint.slope      = linFit(1);
                metPoint.intercept  = linFit(2);
            end
        %if regression coefficients are invalid
        elseif(isnan(linFit(1)))
            linFit(1) = defaultSlope*metPoint.symapField;
            linFit(2) = metPoint.symapField;
            
            metPoint.rawField  = polyval(linFit,gridElev-metPoint.symapElev);
            metPoint.slope     = linFit(1);
            metPoint.normSlope = linFit(1);
            metPoint.intercept = linFit(2);
        else
            
            linFit(2) = metPoint.symapField;
            
            metPoint.rawField = polyval(linFit,gridElev-metPoint.symapElev);
            metPoint.slope     = linFit(1);
            metPoint.intercept = linFit(2);
            metPoint.normSlope = linFit(1)/mean(stationVarAspect);
            metPoint.validRegress = 1;

            %run through station combinations to estimate uncertainty in
            %slope estimate
            nSta = length(stationVarAspect);
            combs = nchoosek(1:nSta,nSta-1);
            cnt = 1;
            combSlp = zeros(1,1);
            for c = 1:length(combs(:,1))
                X = [ones(size(stationElevAspect(combs(c,:)))) stationElevAspect(combs(c,:))];
                
                %if X is square
                if(size(X,1)==size(X,2))
                    %if X is well conditioned
                    if(rcond(X) > tiny)
                        tmpLinFit = calcWeightedRegression(stationElevAspect(combs(c,:)),stationVarAspect(combs(c,:)),...
                                                               finalWeightsAspect(combs(c,:)));
                        elevSlopeTest = tmpLinFit(1)/mean(stationVarAspect(combs(c,:)));
                    else %if not well conditioned, set variables to unrealistic values
                        elevSlopeTest = large;
                    end
                else
                    tmpLinFit = calcWeightedRegression(stationElevAspect(combs(c,:)),stationVarAspect(combs(c,:)),...
                                                           finalWeightsAspect(combs(c,:)));
                    elevSlopeTest = tmpLinFit(1)/mean(stationVarAspect(combs(c,:)));
                end

                if(elevSlopeTest > minSlope && elevSlopeTest < maxSlope)
                    combSlp(cnt) = elevSlopeTest;
                    cnt = cnt + 1;
                end
            end
            
            %if two or more valid combination of stations
            %estimate uncertainty of slope at grid point using standard
            %deviation of estimates
            if(cnt > 2)
                metPoint.normSlopeUncert = std(combSlp);
            end
        end

    elseif(length(stationVarAspect) == 1)  %only one station within range on aspect - revert to nearest with default slope

        linFit(1) = defaultSlope*metPoint.symapField;
        linFit(2) = metPoint.symapField;
        
        metPoint.rawField = polyval(linFit,gridElev-metPoint.symapElev);
        metPoint.slope     = linFit(1);
        metPoint.intercept = linFit(2);
        metPoint.normSlope = linFit(1)/metPoint.symapField;

    elseif(length(stationVarAspect) == 2)  %only 2 stations within range - attempt regression anyway

        linFit = calcWeightedRegression(stationElevAspect,stationVarAspect,finalWeightsAspect);

        elevSlope = linFit(1)/mean(stationVarAspect);

        if(elevSlope < minSlope || elevSlope > maxSlope || isnan(elevSlope))
            linFit(1) = defaultSlope*metPoint.symapField;
            linFit(2) = metPoint.symapField;
            
            metPoint.normSlope = linFit(1)/metPoint.symapField;
            metPoint.slope     = linFit(1);
            metPoint.intercept = linFit(2);
        else
            
            metPoint.intercept = metPoint.symapField;
            metPoint.slope = linFit(1);
            metPoint.normSlope = linFit(1)/metPoint.symapField;

        end
        %override intercept
        linFit(2) = metPoint.symapField;

        metPoint.rawField = polyval(linFit,gridElev-metPoint.symapElev);

    else %no original stations in distance search...

        linFit(1) = defaultSlope*metPoint.symapField;
        linFit(2) = metPoint.symapField;
        
        metPoint.rawField = polyval(linFit,gridElev-metPoint.symapElev);
        metPoint.slope     = linFit(1);
        metPoint.intercept = linFit(2);
        metPoint.normSlope = linFit(1)/metPoint.symapField;

    end %end enough stations?

end