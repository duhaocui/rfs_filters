function est = run_filter(model,meas)

% This is the MATLAB code for the pD-CPHD filter proposed in
% R. Mahler, B.-T. Vo and B.-N. Vo, "CPHD Filtering with unknown clutter rate and detection profile," IEEE Transactions on Signal Processing, Vol. 59, No. 8, pp. 3497-3513, 2011.
% http://ba-ngu.vo-au.com/vo/MVV_PHDrobust.pdf

% There are three versions of filters for this paper
% 1) Lambda-CPHD, 2) pD-CPHD, and 3) Lambda-pD-CPHD as sequentially described in the paper.
% This is the code for pD-CPHD

% ---BibTeX entry
% @ARTICLE{RobustCPHD,
% author={R. P. S. Mahler and B.-T. Vo and B.-N. Vo},
% journal={IEEE Transactions on Signal Processing},
% title={CPHD Filtering With Unknown Clutter Rate and Detection Profile},
% year={2011},
% month={August},
% volume={59},
% number={8},
% pages={3497-3513}} 
%---
% 
% based on the SMC implementation of the PHD filter given in 
%
% B.-N. Vo, S. Singh and A. Doucet, "Sequential Monte Carlo methods for Bayesian Multi-target filtering with Random Finite Sets," IEEE Trans. Aerospace and Electronic Systems, Vol. 41, No. 4, pp. 1224-1245, 2005.
% http://ba-ngu.vo-au.com/vo/VSD_SMCRFS_AES05.pdf
% ---BibTeX entry
% @ARTICLE{SMCRFS,
% author={B.-N. Vo and S. Singh and A. Doucet},
% journal={IEEE Transactions on Aerospace and Electronic Systems},
% title={Sequential Monte Carlo methods for multitarget filtering with random finite sets},
% year={2005},
% month={Oct},
% volume={41},
% number={4},
% pages={1224-1245}} 
%---


%=== Setup

%output variables
est.X= cell(meas.K,1);
est.N= zeros(meas.K,1);
est.L= cell(meas.K,1);
est.pD= cell(meas.K,1);

%filter parameters
filter.J_max= 30000;                                          %total number of particles
filter.J_target= 3000;                                        %generated number of particles per expected target
filter.J_birth= model.L_birth*filter.J_target;                %generated number of particles from birth intensity
filter.beta_factor = 1.1;           %beta factor


filter.N_max= 20;                   %maximum cardinality number (for cardinality distribution)

filter.run_flag= 'disp';            %'disp' or 'silence' for on the fly output

est.filter= filter;

%=== Filtering 

%initial prior
w_update= eps;
m_init= [0.1;0;0.1;0;0.01];
P_init= diag([100 10 100 10 1]).^2;
u_update = 1;
v_update = 1;
x_update= [betarnd(u_update,v_update,1); m_init];

cdn_update= [1; zeros(filter.N_max,1)];

%recursive filtering
for k=1:meas.K
    %---intensity prediction 
    pS_vals= compute_pS(model,x_update); pS_vals= pS_vals(:);
    qS_vals= 1-pS_vals;

    x_predict= gen_newstate_tg(model,x_update);
    w_predict = pS_vals.*w_update;                                                                                      %surviving weights

    for t=1:model.L_birth
        x_birth_temp1= repmat(model.m_birth(:,t), [1, filter.J_target])+model.B_birth(:,:,t)*randn(model.x_dim-1,filter.J_target);
        x_predict= [x_predict [betarnd(model.u_b(t),model.v_b(t),1,filter.J_target); x_birth_temp1]];                                                   %append birth particles
    end     
    
    w_predict= cat(1,w_predict,sum(model.w_birth)*ones(filter.J_birth,1)/filter.J_birth);                               %append birth weights
    
    %---cardinality prediction 
    %surviving cardinality distribution
    survive_cdn_predict = zeros(filter.N_max+1,1);
    for j=0:filter.N_max
        idxj=j+1;
        terms= zeros(filter.N_max+1,1);
        for ell=j:filter.N_max
            idxl= ell+1;
            terms(idxl) = exp(sum(log(1:ell))-sum(log(1:j))-sum(log(1:ell-j))+j*log(pS_vals'*w_update)+(ell-j)*log(qS_vals'*w_update)-ell*log(sum(w_update)))*cdn_update(idxl);
        end
        survive_cdn_predict(idxj) = sum(terms);
    end

    %predicted cardinality= convolution of birth and surviving cardinality distribution
    cdn_predict = zeros(filter.N_max+1,1);
    for n=0:filter.N_max
        idxn=n+1;
        terms= zeros(filter.N_max+1,1);
        for j=0:n
            idxj= j+1;
            terms(idxj)= exp(-sum(model.w_birth)+(n-j)*log(sum(model.w_birth))-sum(log(1:n-j)))*survive_cdn_predict(idxj);
        end
        cdn_predict(idxn) = sum(terms);
    end

    %normalize predicted cardinality distribution
    cdn_predict = cdn_predict/sum(cdn_predict);
    
    
    %---intensity update
    %number of measurements
    m= size(meas.Z{k},2);    
    pD_vals= x_predict(1,:); pD_vals= pD_vals(:);
    qD_vals= 1-pD_vals;
    
    %pre calculation for likelihood values
    if m~=0
        meas_likelihood= zeros(length(w_predict),m);
        for ell=1:m
            meas_likelihood(:,ell)= compute_likelihood(model,meas.Z{k}(:,ell),x_predict)';
        end
    end
    
    %pre calculation for elementary symmetric functions
    XI_vals = zeros(m,1);                        %arguments to esf
    for ell=1:m
       XI_vals(ell) = sum(pD_vals.*w_predict.*meas_likelihood(:,ell)/model.pdf_c);
    end
    
    esfvals_E = esf(XI_vals);                   %calculate esf for entire observation set
    esfvals_D = zeros(m,m);                     %calculate esf with each observation index removed one-by-one
    for ell=1:m
        esfvals_D(:,ell) = esf([XI_vals(1:ell-1);XI_vals(ell+1:m)]);
    end
    
    %pre calculation for upsilons
    upsilon0_E = zeros(filter.N_max+1,1);
    upsilon1_E = zeros(filter.N_max+1,1);
    upsilon1_D = zeros(filter.N_max+1,m);
    
    for n=0:filter.N_max
        idxn= n+1;
        
        terms0_E= zeros(min(m,n)+1,1);  %calculate upsilon0_E(idxn)
        for j=0:min(m,n)
            idxj= j+1;
            terms0_E(idxj) = exp(-model.lambda_c+(m-j)*log(model.lambda_c)+sum(log(1:n))-sum(log(1:n-j))+(n-j)*log(qD_vals'*w_predict)-n*log(sum(w_predict)))*esfvals_E(idxj);
        end
        upsilon0_E(idxn)= sum(terms0_E);
        
        terms1_E= zeros(min(m,n)+1,1);  %calculate upsilon1_E(idxn)
        for j=0:min(m,n)
            idxj= j+1;
            if n>=j+1
                terms1_E(idxj) = exp(-model.lambda_c+(m-j)*log(model.lambda_c)+sum(log(1:n))-sum(log(1:n-(j+1)))+(n-(j+1))*log(qD_vals'*w_predict)-n*log(sum(w_predict)))*esfvals_E(idxj);
            end
        end
        upsilon1_E(idxn)= sum(terms1_E);
        
        if m~= 0                        %calculate upsilon1_D(idxn,:) if m>0
            terms1_D= zeros(min((m-1),n)+1,m);
            for ell=1:m
                for j=0:min((m-1),n)
                    idxj= j+1;
                    if n>=j+1
                        terms1_D(idxj,ell) = exp(-model.lambda_c+((m-1)-j)*log(model.lambda_c)+sum(log(1:n))-sum(log(1:n-(j+1)))+(n-(j+1))*log(qD_vals'*w_predict)-n*log(sum(w_predict)))*esfvals_D(idxj,ell);
                    end
                end
            end
            upsilon1_D(idxn,:)= sum(terms1_D,1);
        end
    end

    %missed detection weight
    pseudo_likelihood= (upsilon1_E'*cdn_predict)/(upsilon0_E'*cdn_predict)*qD_vals;
    
    if m~=0
        %m detection weights
        for ell=1:m
            %measurement likeihoods precalculated and stored
            pseudo_likelihood = pseudo_likelihood+(upsilon1_D(:,ell)'*cdn_predict)/(upsilon0_E'*cdn_predict)*pD_vals.*meas_likelihood(:,ell)/model.pdf_c;
        end
    end
    w_update= pseudo_likelihood.*w_predict;
    x_update= x_predict;    
    
    %---cardinality update
    cdn_update= upsilon0_E.*cdn_predict;
    cdn_update= cdn_update/sum(cdn_update);
    
    %---for diagnostics
    w_posterior= w_update;
    
    %---resampling
    J_rsp= min(ceil(sum(w_update)*filter.J_target),filter.J_max);
    idx= randsample(length(w_update),J_rsp,true,w_update); %idx= resample(w_update,J_rsp);
    w_update= sum(w_update)*ones(J_rsp,1)/J_rsp;
    x_update= x_update(:,idx);
 
    %--- state extraction 
    pD_tmp = [];
    if sum(w_update) > .5
        [x_c,I_c]= our_kmeans(x_update,w_update,1);
        est.N(k)= 0;
        for j=1:size(x_c,2);
            if sum(w_update(I_c{j})) > .5,
                pD_tmp = [pD_tmp; x_update(1,I_c{j})*w_update(I_c{j})];
                est.X{k}= [ est.X{k} x_c(:,j) ];
                est.N(k)= est.N(k)+1;
            end
        end
    else
        est.N(k)= 0; est.X{k}= [];
    end
    est.pD{k} = x_update(1,:)*w_update(:)/sum(w_update);
    %---display diagnostics
    if ~strcmp(filter.run_flag,'silence')
        disp([' time= ',num2str(k),...
         ' #avg pD=' num2str(est.pD{k},4),...
         ' #eap target=' num2str(sum(w_update),4),...
         ' #est card=' num2str(est.N(k),4),...
         ' Neff_updt= ',num2str(round(1/sum((w_posterior/sum(w_posterior)).^2)))...
         ' Neff_rsmp= ',num2str(round(1/sum((w_update/sum(w_update)).^2)))   ]);
    end

end

            